#!/usr/bin/env python3
"""Experimental LLM-driven explorer for CFL Android UI."""

import argparse
import json
import os
import re
import ast
import sys
import textwrap
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import requests
import xml.etree.ElementTree as ET


BOUNDS_RE = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


ACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "action": {"type": "string", "enum": ["tap", "type", "key", "done"]},
        "x": {"type": ["integer", "null"]},
        "y": {"type": ["integer", "null"]},
        "text": {"type": "string"},
        "keycode": {"type": ["integer", "null"]},
        "reason": {"type": "string"},
    },
    "required": ["action"],
    "additionalProperties": True,
}

def _norm_base(url: str) -> str:
    url = (url or "").rstrip("/")
    if url.endswith("/v1"):
        url = url[:-3]
    return url
    
def _api_base() -> str:
    base = os.environ.get("OPENAI_BASE_URL", "http://127.0.0.1:8001").rstrip("/")
    # Certains mettent déjà /v1, d'autres non
    if base.endswith("/v1"):
        return base
    return base + "/v1"


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


def log(msg: str) -> None:
    print(f"[*] {msg}", file=sys.stderr)


def warn(msg: str) -> None:
    print(f"[!] {msg}", file=sys.stderr)


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


def build_prompt(instruction: str, state_summary: str) -> str:
    return textwrap.dedent(
        f"""
        You control an Android app over adb (uiautomator + touch). Choose the safest next step.
        Respond with a STRICT JSON (no code fences, no comments) like:
        {{"action":"tap","x":518,"y":407,"text":"","keycode":null,"reason":"Tap start field"}}
        - action=tap => use center coordinates inside the target bounds (integers only)
        - action=type => fill text field; leave x/y empty
        - action=key => send Android keycode (e.g., 4 for BACK)
        - action=done => goal reached or blocked
        Rules: stay inside screen bounds, avoid risky taps like (0,0), prefer clickable & enabled nodes, keep moves deterministic.

        Instruction: {instruction}

        Current UI (summarized):
        {state_summary}
        """
    ).strip()


def _strip_code_fences(text: str) -> str:
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z0-9]*\s*", "", text)
        text = re.sub(r"```\s*$", "", text)
    return text.strip()


def parse_llm_response(content: str) -> dict:
    if content is None:
        raise ValueError("LLM content empty")

    s = content.strip()

    # enlève ```json ... ```
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s, flags=re.IGNORECASE | re.DOTALL).strip()

    # récupère le premier {...} si le modèle bavarde
    m = re.search(r"\{.*\}", s, flags=re.DOTALL)
    if m:
        s = m.group(0).strip()

    # 1) vrai JSON
    try:
        obj = json.loads(s)
    except Exception:
        # 2) parfois Qwen renvoie un dict Python avec quotes simples -> ast.literal_eval
        try:
            obj = ast.literal_eval(s)
        except Exception as e:
            raise ValueError(f"LLM response is not valid JSON: {e}")

    if not isinstance(obj, dict):
        raise ValueError("LLM response did not produce an object")

    return obj

def safe_action_from_error(err: Exception) -> dict:
    return {"action": "done", "reason": f"LLM parse/call error: {err}"}
    
def call_llm(prompt: str, model: str) -> dict:
    base = _norm_base(os.getenv("OPENAI_BASE_URL", "http://127.0.0.1:8001"))
    api_key = os.getenv("OPENAI_API_KEY", "dummy")
    url = f"{base}/v1/chat/completions"

    timeout = float(os.getenv("OPENAI_TIMEOUT", "180"))
    max_tokens = int(os.getenv("LLM_MAX_TOKENS", "128"))
    temperature = float(os.getenv("LLM_TEMPERATURE", "0"))

    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are an automation planner.\n"
                    "Return ONLY a single JSON object, no markdown, no extra text.\n"
                    "Use double quotes.\n"
                    "Schema: {\"action\":\"tap|type|key|done\",\"x\":int,\"y\":int,"
                    "\"text\":string,\"keycode\":int|null,\"reason\":string}\n"
                    "If unsure, return {\"action\":\"done\",\"reason\":\"...\"}."
                ),
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
        # llama-server ignore peut-être response_format, mais ça ne casse rien :
        "response_format": {"type": "json_object"},
        # Optionnel: stop dès que ça ferme l’objet (ça aide certains modèles)
        "stop": ["\n\n", "```"],
    }

    r = requests.post(
        url,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        json=payload,
        timeout=timeout,
    )
    r.raise_for_status()
    data = r.json()

    # OpenAI-chat style
    content = ""
    try:
        content = data["choices"][0]["message"].get("content") or ""
    except Exception:
        # fallback (au cas où)
        content = data["choices"][0].get("text") or ""

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
        except Exception as exc:  # noqa: BLE001
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
        except Exception as exc:  # noqa: BLE001
            raise ValueError("Key action requires numeric keycode") from exc

    return safe


def main() -> int:
    parser = argparse.ArgumentParser(description="LLM-guided Android explorer")
    parser.add_argument("--instruction", required=True, help="Goal for the LLM")
    parser.add_argument("--xml", required=True, help="Path to uiautomator dump XML")
    parser.add_argument("--model", default=os.environ.get("LLM_MODEL", "local-model"))
    parser.add_argument("--limit", type=int, default=80, help="Max candidates to surface")
    args = parser.parse_args()

    candidates, size = extract_candidates(args.xml, limit=args.limit)
    state_summary, state_json = build_state_summary(candidates, size)

    log("State summary ready")
    log(state_summary)
    log("State JSON (debug):")
    log(json.dumps(state_json, ensure_ascii=False))

    prompt = build_prompt(args.instruction, state_summary)
    try:
        raw_action = call_llm(prompt, args.model)
    except Exception as e:
        print(json.dumps(safe_action_from_error(e), ensure_ascii=False))
        return 0
    log(f"Raw LLM response: {raw_action}")

    action = validate_action(raw_action, size)
    log(f"Validated action: {action}")

    print(json.dumps(action, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
