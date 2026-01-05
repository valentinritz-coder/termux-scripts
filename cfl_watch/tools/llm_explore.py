#!/usr/bin/env python3
"""Experimental LLM-driven explorer for CFL Android UI."""

import argparse
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


def parse_llm_response(raw: str) -> Dict:
    cleaned = _strip_code_fences(raw)
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        pass

    brace_match = re.search(r"\{.*\}", cleaned, flags=re.DOTALL)
    if brace_match:
        try:
            return json.loads(brace_match.group(0))
        except json.JSONDecodeError:
            pass

    raise ValueError("LLM response is not valid JSON")


def call_llm(prompt: str, model: str) -> Dict:
    base_url = os.environ.get("OPENAI_BASE_URL", "http://127.0.0.1:8000").rstrip("/")
    api_key = os.environ.get("OPENAI_API_KEY", "dummy-key")
    url = f"{base_url}/v1/chat/completions"

    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": "You are a careful Android UI navigator. Respond ONLY with the requested JSON.",
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.2,
    }

    headers = {"Authorization": f"Bearer {api_key}"}
    resp = requests.post(url, json=payload, headers=headers, timeout=60)
    resp.raise_for_status()
    data = resp.json()
    content = data.get("choices", [{}])[0].get("message", {}).get("content", "")
    if not content:
        raise ValueError("LLM response missing content")
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
    raw_action = call_llm(prompt, args.model)
    log(f"Raw LLM response: {raw_action}")

    action = validate_action(raw_action, size)
    log(f"Validated action: {action}")

    print(json.dumps(action, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
