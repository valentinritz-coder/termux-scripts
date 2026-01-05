#!/usr/bin/env python3
"""Experimental LLM-driven explorer for CFL Android UI.

Reads a uiautomator XML dump, extracts clickable candidates, asks an LLM for the next
safe action, and outputs a single JSON action object.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys
import textwrap
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import requests
import xml.etree.ElementTree as ET


BOUNDS_RE = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


def log(msg: str) -> None:
    print(f"[*] {msg}", file=sys.stderr)


def warn(msg: str) -> None:
    print(f"[!] {msg}", file=sys.stderr)


def _norm_base(url: str) -> str:
    """Normalize base URL, removing trailing / and optional /v1 suffix."""
    url = (url or "").rstrip("/")
    if url.endswith("/v1"):
        url = url[:-3]
    return url


def _chat_completions_url() -> str:
    base = _norm_base(os.getenv("OPENAI_BASE_URL", "http://127.0.0.1:8001"))
    return f"{base}/v1/chat/completions"


@dataclass
class Candidate:
    idx: int
    class_name: str
    resource_id: str
    text: str
    content_desc: str
    clickable: bool
    enabled: bool
    bounds: str
    center: Optional[Tuple[int, int]]

    def summary_line(self) -> str:
        cx, cy = (self.center or ("?", "?"))
        parts = [
            f"[{self.idx}] {self.class_name or '-'}",
            f"id={self.resource_id or '-'}",
            f"text={self.text or '-'}",
            f"desc={self.content_desc or '-'}",
            f"click={self.clickable}",
            f"enabled={self.enabled}",
            f"center=({cx},{cy})",
            f"bounds={self.bounds or '-'}",
        ]
        return " | ".join(parts)


def parse_bounds(raw: Optional[str]) -> Optional[Tuple[int, int, int, int]]:
    if not raw:
        return None
    m = BOUNDS_RE.match(raw.strip())
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 <= x1 or y2 <= y1:
        return None
    return x1, y1, x2, y2


def extract_candidates(xml_path: str, limit: int = 80) -> Tuple[List[Candidate], Dict[str, int]]:
    tree = ET.parse(xml_path)
    root = tree.getroot()

    candidates: List[Candidate] = []
    max_x, max_y = 0, 0

    for idx, node in enumerate(root.iter("node")):
        attrs = node.attrib
        bounds = attrs.get("bounds", "")
        parsed = parse_bounds(bounds)
        center = None
        if parsed:
            x1, y1, x2, y2 = parsed
            center = ((x1 + x2) // 2, (y1 + y2) // 2)
            max_x, max_y = max(max_x, x2), max(max_y, y2)

        candidates.append(
            Candidate(
                idx=idx,
                class_name=attrs.get("class", ""),
                resource_id=attrs.get("resource-id", ""),
                text=attrs.get("text", ""),
                content_desc=attrs.get("content-desc", ""),
                clickable=attrs.get("clickable") == "true",
                enabled=attrs.get("enabled") != "false",
                bounds=bounds,
                center=center,
            )
        )

    clickable = [c for c in candidates if c.clickable]
    others = [c for c in candidates if not c.clickable]
    ordered = (clickable + others)[:limit]

    size = {
        "width": max(max_x, 1080),
        "height": max(max_y, 2400),
        "total_nodes": len(candidates),
        "clickable_nodes": len(clickable),
    }
    return ordered, size


def build_state_summary(candidates: List[Candidate], size: Dict[str, int]) -> Tuple[str, Dict]:
    lines = [
        f"Nodes: total={size['total_nodes']} clickable={size['clickable_nodes']} (showing {len(candidates)})",
        "Use center coordinates for taps; prefer clickable + enabled elements.",
    ]
    for c in candidates:
        lines.append(c.summary_line())

    state_summary = "\n".join(lines)
    state_json = {
        "size": size,
        "candidates": [c.__dict__ for c in candidates],
    }
    return state_summary, state_json


def compact_state(state_json: Dict, max_candidates: int = 12, maxlen: int = 80) -> Dict:
    """Keep only clickable+enabled candidates and clip text/desc to keep prompts small."""
    def clip(s: str) -> str:
        s = (s or "")
        return s if len(s) <= maxlen else s[: maxlen - 1] + "…"

    out = []
    for c in state_json.get("candidates", []):
        if c.get("clickable") and c.get("enabled"):
            out.append(
                {
                    "idx": c.get("idx"),
                    "id": c.get("resource_id", "") or "",
                    "text": clip(c.get("text", "") or ""),
                    "desc": clip(c.get("content_desc", "") or ""),
                    "center": c.get("center"),
                }
            )

    return {"size": state_json.get("size", {}), "candidates": out[:max_candidates]}


def build_prompt(instruction: str, compact_ui_json_text: str) -> str:
    return textwrap.dedent(
        f"""
        You control an Android app over adb (uiautomator dump + touch + key events).
        Choose the SAFEST next step towards the goal.

        Output MUST be a single STRICT JSON object (no markdown, no code fences, no extra text).
        Example:
        {{"action":"tap","x":518,"y":407,"text":"","keycode":null,"reason":"Tap start field"}}

        Allowed actions:
        - tap: tap at integer x/y (use the provided "center" coords; stay within screen bounds; avoid (0,0))
        - type: provide "text" only (x/y null)
        - key: provide Android keycode only (e.g., 4 for BACK)
        - done: if goal reached or blocked

        Rules:
        - Prefer clickable AND enabled candidates.
        - Be deterministic. Do not guess coordinates not present in candidates.
        - Keep reason short.

        Goal: {instruction}

        Current UI (compact JSON):
        {compact_ui_json_text}
        """
    ).strip()


def parse_llm_response(content: str) -> Dict:
    if content is None:
        raise ValueError("LLM content empty")

    s = content.strip()

    # Remove ```json fences if any
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s, flags=re.IGNORECASE | re.DOTALL).strip()

    # Extract the first {...} block if the model babbles
    m = re.search(r"\{.*\}", s, flags=re.DOTALL)
    if m:
        s = m.group(0).strip()

    # 1) Strict JSON
    try:
        obj = json.loads(s)
    except Exception:
        # 2) Some local models answer with Python dict-like text
        try:
            obj = ast.literal_eval(s)
        except Exception as e:
            raise ValueError(f"LLM response is not valid JSON: {e}")

    if not isinstance(obj, dict):
        raise ValueError("LLM response did not produce an object")

    return obj


def safe_action_from_error(err: Exception) -> Dict:
    return {"action": "done", "reason": f"LLM parse/call error: {err}"}


def _post_json(url: str, headers: Dict[str, str], payload: Dict, timeout: float) -> Dict:
    r = requests.post(url, headers=headers, json=payload, timeout=timeout)
    if not r.ok:
        raise RuntimeError(f"LLM HTTP {r.status_code}: {r.text[:2000]}")
    return r.json()


def call_llm(prompt: str, model: str) -> Dict:
    url = _chat_completions_url()
    api_key = os.getenv("OPENAI_API_KEY", "dummy")

    timeout = float(os.getenv("OPENAI_TIMEOUT", "180"))
    max_tokens = int(os.getenv("LLM_MAX_TOKENS", "128"))
    temperature = float(os.getenv("LLM_TEMPERATURE", "0"))

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }

    system = (
        "You are an automation planner.\n"
        "Return ONLY a single JSON object, no markdown, no extra text.\n"
        "Use double quotes.\n"
        "Schema: {\"action\":\"tap|type|key|done\",\"x\":int|null,\"y\":int|null,"
        "\"text\":string,\"keycode\":int|null,\"reason\":string}\n"
        "If unsure, return {\"action\":\"done\",\"reason\":\"...\"}."
    )

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
        # Some servers support it, others crash on it. We'll retry without if needed.
        "response_format": {"type": "json_object"},
        # "stop" is often counter-productive; keep it out by default.
    }

    # Attempt 1: with response_format
    try:
        data = _post_json(url, headers, payload, timeout=timeout)
    except RuntimeError as e:
        # Attempt 2: remove fields that many local servers reject
        warn(f"First LLM call failed, retrying without response_format. err={e}")
        payload2 = dict(payload)
        payload2.pop("response_format", None)
        data = _post_json(url, headers, payload2, timeout=timeout)

    # OpenAI-chat style
    content = ""
    try:
        content = data["choices"][0]["message"].get("content") or ""
    except Exception:
        content = data.get("choices", [{}])[0].get("text") or ""

    return parse_llm_response(content)


def validate_action(action: Dict, size: Dict[str, int]) -> Dict:
    allowed = {"tap", "type", "key", "done"}
    act = str(action.get("action", "")).strip().lower()
    if act not in allowed:
        raise ValueError(f"Invalid action: {act}")

    safe = {
        "action": act,
        "x": None,
        "y": None,
        "text": "",
        "keycode": None,
        "reason": (action.get("reason") or "").strip(),
    }

    if act == "tap":
        try:
            x = int(action.get("x"))
            y = int(action.get("y"))
        except Exception as exc:
            raise ValueError("Tap requires integer x/y") from exc

        max_x = max(1, int(size.get("width", 1080)))
        max_y = max(1, int(size.get("height", 2400)))

        if x <= 0 or y <= 0:
            raise ValueError("Tap coordinates must be positive and non-zero")
        if x > max_x or y > max_y:
            raise ValueError("Tap coordinates outside screen bounds")

        safe["x"], safe["y"] = x, y

    elif act == "type":
        txt = action.get("text")
        if txt is None:
            raise ValueError("Type action missing text")
        safe["text"] = str(txt)

    elif act == "key":
        try:
            safe["keycode"] = int(action.get("keycode"))
        except Exception as exc:
            raise ValueError("Key action requires numeric keycode") from exc

    return safe


def main() -> int:
    parser = argparse.ArgumentParser(description="LLM-guided Android explorer")
    parser.add_argument("--instruction", required=True, help="Goal for the LLM")
    parser.add_argument("--xml", required=True, help="Path to uiautomator dump XML")
    parser.add_argument("--model", default=os.environ.get("LLM_MODEL", "local-model"))
    parser.add_argument("--limit", type=int, default=80, help="Max candidates to surface")
    parser.add_argument("--compact-candidates", type=int, default=int(os.getenv("LLM_UI_MAX_CANDIDATES", "12")))
    parser.add_argument("--compact-maxlen", type=int, default=int(os.getenv("LLM_UI_MAXLEN", "80")))
    parser.add_argument("--debug-full-summary", action="store_true", help="Log full state summary (can be huge)")
    args = parser.parse_args()

    candidates, size = extract_candidates(args.xml, limit=args.limit)
    state_summary, state_json = build_state_summary(candidates, size)

    compact = compact_state(state_json, max_candidates=args.compact_candidates, maxlen=args.compact_maxlen)
    compact_text = json.dumps(compact, ensure_ascii=False, indent=2)

    log("State ready")
    if args.debug_full_summary:
        log(state_summary)
    log("State JSON compact (debug):")
    log(compact_text)

    prompt = build_prompt(args.instruction, compact_text)

    log(f"LLM endpoint: {_chat_completions_url()}")
    log(f"Prompt chars={len(prompt)}")

    try:
        raw_action = call_llm(prompt, args.model)
    except Exception as e:
        print(json.dumps(safe_action_from_error(e), ensure_ascii=False))
        return 0

    log(f"Raw LLM response: {raw_action}")

    try:
        action = validate_action(raw_action, size)
    except Exception as e:
        print(json.dumps(safe_action_from_error(e), ensure_ascii=False))
        return 0

    log(f"Validated action: {action}")
    print(json.dumps(action, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
