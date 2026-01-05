#!/usr/bin/env python3
"""
LLM-driven Android UI explorer (CFL) with guardrails.

Key improvements vs your draft:
- Removes duplicated code + fixes undefined variable bugs.
- Extracts richer node attrs (package, focused, focusable) to detect "typing" states.
- Detects UI phase (journey form vs picking start/destination).
- Adds rule-based "fast path" to prevent dumb loops (select visible Luxembourg/Arlon).
- De-prioritizes / ignores keyboard (IME) keys to stop tapping ESC like a maniac.
- Stronger prompt context (targets + phase + safety rules).
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys
import textwrap
from collections import Counter
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

import requests
import xml.etree.ElementTree as ET


BOUNDS_RE = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


# ---------- logging ----------


def log(msg: str) -> None:
    print(f"[*] {msg}", file=sys.stderr)


def warn(msg: str) -> None:
    print(f"[!] {msg}", file=sys.stderr)


# ---------- URL helpers ----------


def _norm_base(url: str) -> str:
    url = (url or "").rstrip("/")
    if url.endswith("/v1"):
        url = url[:-3]
    return url


def _chat_completions_url() -> str:
    base = _norm_base(os.getenv("OPENAI_BASE_URL", "http://127.0.0.1:8001"))
    return f"{base}/v1/chat/completions"


# ---------- UI model ----------


@dataclass(frozen=True)
class Candidate:
    idx: int
    package: str
    class_name: str
    resource_id: str
    text: str
    content_desc: str
    clickable: bool
    enabled: bool
    focusable: bool
    focused: bool
    bounds: str
    center: Optional[Tuple[int, int]]

    def summary_line(self) -> str:
        cx, cy = (self.center or ("?", "?"))
        parts = [
            f"[{self.idx}] {self.class_name or '-'}",
            f"pkg={self.package or '-'}",
            f"id={self.resource_id or '-'}",
            f"text={self.text or '-'}",
            f"desc={self.content_desc or '-'}",
            f"click={self.clickable}",
            f"enabled={self.enabled}",
            f"focused={self.focused}",
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


def _bool_attr(v: Optional[str], default: bool = False) -> bool:
    if v is None:
        return default
    return v.strip().lower() == "true"


def extract_candidates(xml_path: str) -> Tuple[List[Candidate], Dict[str, int], str]:
    """
    Returns: (all_candidates, size, dominant_app_package)
    """
    tree = ET.parse(xml_path)
    root = tree.getroot()

    candidates: List[Candidate] = []
    max_x, max_y = 0, 0
    packages: List[str] = []

    # uiautomator dump typically uses attribute "package"
    for idx, node in enumerate(root.iter("node")):
        a = node.attrib
        bounds = a.get("bounds", "")
        parsed = parse_bounds(bounds)
        center = None
        if parsed:
            x1, y1, x2, y2 = parsed
            center = ((x1 + x2) // 2, (y1 + y2) // 2)
            max_x, max_y = max(max_x, x2), max(max_y, y2)

        pkg = a.get("package", "") or a.get("packageName", "")
        if pkg:
            packages.append(pkg)

        candidates.append(
            Candidate(
                idx=idx,
                package=pkg,
                class_name=a.get("class", ""),
                resource_id=a.get("resource-id", ""),
                text=a.get("text", ""),
                content_desc=a.get("content-desc", ""),
                clickable=_bool_attr(a.get("clickable"), default=False),
                enabled=not (a.get("enabled", "").strip().lower() == "false"),
                focusable=_bool_attr(a.get("focusable"), default=False),
                focused=_bool_attr(a.get("focused"), default=False),
                bounds=bounds,
                center=center,
            )
        )

    size = {
        "width": max(max_x, 1080),
        "height": max(max_y, 2400),
        "total_nodes": len(candidates),
        "clickable_nodes": sum(1 for c in candidates if c.clickable),
    }

    dominant_pkg = ""
    if packages:
        dominant_pkg = Counter(packages).most_common(1)[0][0]

    return candidates, size, dominant_pkg


# ---------- state + phase ----------


def _norm(s: str) -> str:
    return (s or "").strip().lower()


def parse_targets_from_instruction(instruction: str) -> Dict[str, str]:
    """
    Tries to find something like "Luxembourg -> Arlon" in a noisy instruction.
    Returns {"start": "...", "destination": "..."} when possible.
    """
    s = instruction or ""
    # pick the *last* match to survive prefixes like "Ouvre ... itinéraire ..."
    patterns = [
        r"([A-Za-zÀ-ÿ0-9' -]{2,})\s*(?:->|→)\s*([A-Za-zÀ-ÿ0-9' -]{2,})",
        r"([A-Za-zÀ-ÿ0-9' -]{2,})\s*(?:à|to)\s*([A-Za-zÀ-ÿ0-9' -]{2,})",
    ]
    for pat in patterns:
        m_all = list(re.finditer(pat, s, flags=re.IGNORECASE))
        if m_all:
            m = m_all[-1]
            start = m.group(1).strip(" -\t\n")
            dest = m.group(2).strip(" -\t\n")
            return {"start": start, "destination": dest}
    return {"start": "", "destination": ""}


def detect_phase(all_nodes: List[Candidate]) -> str:
    """
    Coarse phase detection:
    - "journey_form": CFL journey form with input_start/input_target
    - "pick_start": location picker currently selecting start
    - "pick_destination": location picker currently selecting destination
    - "unknown": anything else
    """
    # journey form IDs seen in your logs
    has_input_start = any("id/input_start" in c.resource_id for c in all_nodes)
    has_input_target = any("id/input_target" in c.resource_id for c in all_nodes)
    if has_input_start or has_input_target:
        return "journey_form"

    # picker field id in your logs
    picker_field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_location_name")), None)
    if picker_field:
        t = _norm(picker_field.text)
        # your UI shows "Select start" / "Select destination"
        if "start" in t:
            return "pick_start"
        if "destination" in t or "target" in t:
            return "pick_destination"
        # fallback: unknown picker
        return "pick_unknown"

    return "unknown"


def is_ime_candidate(c: Candidate) -> bool:
    """
    Keyboard keys are poison for an automation planner.
    We classify IME nodes by package and by typical key labels.
    """
    pkg = _norm(c.package)
    if "inputmethod" in pkg or "keyboard" in pkg:
        return True

    # heuristic for "Hacker's Keyboard"-like overlays: ESC/ALT/CTRL etc
    txt = (c.text or "").strip()
    if txt in {"ESC", "ALT", "CTRL", "HOME", "END", "PGUP", "PGDN", "↹", "⇳", "☰", "↑", "↓", "←", "→"}:
        return True

    return False


def score_candidate(c: Candidate, dominant_pkg: str) -> int:
    """
    Higher score => earlier in the surfaced list.
    """
    s = 0
    if c.clickable and c.enabled:
        s += 100
    if c.package and dominant_pkg and c.package == dominant_pkg:
        s += 40
    if c.resource_id:
        s += 10
    if c.text or c.content_desc:
        s += 5
    if "EditText" in (c.class_name or ""):
        s += 20
    if c.focused:
        s += 15
    if is_ime_candidate(c):
        s -= 200  # shove it to the bottom
    return s


def surface_candidates(all_nodes: List[Candidate], dominant_pkg: str, limit: int) -> List[Candidate]:
    scored = [(score_candidate(c, dominant_pkg), c.idx, c) for c in all_nodes]
    scored.sort(key=lambda t: (t[0], -t[1]), reverse=True)  # stable-ish, deterministic
    out: List[Candidate] = []
    for _, _, c in scored:
        out.append(c)
        if len(out) >= limit:
            break
    return out


def build_state_summary(surfaced: List[Candidate], size: Dict[str, int], phase: str, targets: Dict[str, str]) -> Tuple[str, Dict]:
    lines = [
        f"Phase: {phase}",
        f"Targets: start='{targets.get('start','')}' destination='{targets.get('destination','')}'",
        f"Nodes: total={size['total_nodes']} clickable={size['clickable_nodes']} (showing {len(surfaced)})",
        "Use center coordinates for taps; prefer clickable + enabled elements.",
        "Never tap on keyboard keys (ESC/ALT/etc). Use action=type or key codes instead.",
    ]
    for c in surfaced:
        lines.append(c.summary_line())

    state_summary = "\n".join(lines)
    state_json = {
        "phase": phase,
        "targets": targets,
        "size": size,
        "candidates": [c.__dict__ for c in surfaced],
    }
    return state_summary, state_json


def compact_state(state: Dict, max_candidates: int = 12, maxlen: int = 80) -> Dict:
    def clip(s: str) -> str:
        s = (s or "")
        return s if len(s) <= maxlen else s[: maxlen - 1] + "…"

    out = []
    for c in state.get("candidates", []):
        if c.get("clickable") and c.get("enabled"):
            out.append(
                {
                    "idx": c.get("idx"),
                    "pkg": c.get("package", ""),
                    "id": c.get("resource_id", ""),
                    "text": clip(c.get("text", "")),
                    "desc": clip(c.get("content_desc", "")),
                    "focused": bool(c.get("focused")),
                    "center": c.get("center"),
                }
            )
    return {
        "phase": state.get("phase", ""),
        "targets": state.get("targets", {}),
        "size": state.get("size", {}),
        "candidates": out[:max_candidates],
    }


# ---------- rule-based “fast path” ----------


def _contains_city(c: Candidate, city: str) -> bool:
    if not city:
        return False
    city_l = _norm(city)
    text = _norm(c.text)
    desc = _norm(c.content_desc)
    # prefer list entries: usually desc contains "Luxembourg, ..." etc
    return (city_l in desc) or (city_l == text) or (city_l in text)


def rule_based_action(all_nodes: List[Candidate], phase: str, targets: Dict[str, str]) -> Optional[Dict]:
    """
    Return an action dict or None if we want LLM fallback.
    """
    start = targets.get("start", "").strip()
    dest = targets.get("destination", "").strip()

    # 1) On journey form: tap the right field in order (start then destination), else press search.
    if phase == "journey_form":
        start_field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_start")), None)
        dest_field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_target")), None)
        search_btn = next(
            (c for c in all_nodes if c.resource_id.endswith(":id/button_search") or c.resource_id.endswith(":id/button_search_default")),
            None,
        )

        def is_placeholder(txt: str) -> bool:
            t = _norm(txt)
            return t in {"", "select start", "select destination"} or "select" in t

        if start_field and start and is_placeholder(start_field.text) and start_field.center:
            return {"action": "tap", "x": start_field.center[0], "y": start_field.center[1], "reason": f"Open start field to set '{start}'"}
        if dest_field and dest and is_placeholder(dest_field.text) and dest_field.center:
            return {"action": "tap", "x": dest_field.center[0], "y": dest_field.center[1], "reason": f"Open destination field to set '{dest}'"}
        if search_btn and search_btn.center:
            return {"action": "tap", "x": search_btn.center[0], "y": search_btn.center[1], "reason": "Launch search"}

        return None

    # 2) On picker: if target city is already visible in list -> tap it directly.
    if phase in {"pick_start", "pick_destination", "pick_unknown"}:
        want = start if phase == "pick_start" else dest if phase == "pick_destination" else (start or dest)

        # Find tappable list entry (not favorite button, not voice, not nav up)
        list_entries = [
            c
            for c in all_nodes
            if c.clickable
            and c.enabled
            and c.center
            and not c.resource_id.endswith(":id/button_favorite")
            and not c.resource_id.endswith(":id/button_location_voice")
            and (c.resource_id == "" or "id/" not in c.resource_id)  # list rows often have empty id
        ]

        # Prefer an entry that contains the wanted city
        matching = [c for c in list_entries if _contains_city(c, want)]
        if want and matching:
            # choose the most “specific” one (longer desc), deterministic
            matching.sort(key=lambda c: (len((c.content_desc or "").strip()), c.idx), reverse=True)
            best = matching[0]
            return {"action": "tap", "x": best.center[0], "y": best.center[1], "reason": f"Select '{want}' from visible list"}

        # If not visible, type into the picker field (but only if focused, else focus it first).
        field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_location_name")), None)
        if field and field.center and want:
            if field.focused:
                return {"action": "type", "text": want, "reason": f"Type '{want}' in location search field"}
            # not focused: focus it first
            return {"action": "tap", "x": field.center[0], "y": field.center[1], "reason": "Focus location input field"}

        # If keyboard overlay is there, close it instead of tapping keys
        # (Back is keycode 4)
        if any(is_ime_candidate(c) for c in all_nodes):
            return {"action": "key", "keycode": 4, "reason": "Close keyboard overlay (BACK)"}

        return None

    return None


# ---------- prompt + LLM ----------


def build_prompt(instruction: str, state_summary: str, phase: str, targets: Dict[str, str]) -> str:
    # Strong, explicit context to avoid “tap field again” loops
    start = targets.get("start", "")
    dest = targets.get("destination", "")

    return textwrap.dedent(
        f"""
        You control an Android app over adb (uiautomator + touch).
        Your overall task: {instruction}

        Current phase: {phase}
        Target route:
        - Start must be: {start}
        - Destination must be: {dest}

        IMPORTANT RULES:
        - Never tap on keyboard keys (ESC/ALT/CTRL/etc). If typing is needed, use action=type.
        - If you are picking START, do NOT select the destination city by mistake.
        - Prefer selecting an already visible list entry (e.g., "Luxembourg, ..." or "Arlon, ...") rather than re-tapping the same field.
        - Keep actions deterministic and safe.

        Respond with a STRICT JSON (no code fences, no comments), like:
        {{"action":"tap","x":518,"y":407,"text":"","keycode":null,"reason":"Tap start field"}}

        Allowed actions:
        - tap: requires integer x,y inside screen bounds
        - type: requires "text" (x/y omitted)
        - key: requires "keycode" (e.g., 4 BACK, 66 ENTER)
        - done: if goal reached or blocked

        Current UI (summarized):
        {state_summary}
        """
    ).strip()


def parse_llm_response(content: str) -> Dict:
    if content is None:
        raise ValueError("LLM content empty")

    s = content.strip()
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s, flags=re.IGNORECASE | re.DOTALL).strip()

    m = re.search(r"\{.*\}", s, flags=re.DOTALL)
    if m:
        s = m.group(0).strip()

    try:
        obj = json.loads(s)
    except Exception:
        try:
            obj = ast.literal_eval(s)
        except Exception as e:
            raise ValueError(f"LLM response is not valid JSON: {e}") from e

    if not isinstance(obj, dict):
        raise ValueError("LLM response did not produce an object")
    return obj


def call_llm(prompt: str, model: str) -> Dict:
    url = _chat_completions_url()
    api_key = os.getenv("OPENAI_API_KEY", "dummy")

    timeout = float(os.getenv("OPENAI_TIMEOUT", "60"))
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
                    'Schema: {"action":"tap|type|key|done","x":int,"y":int,"text":string,"keycode":int|null,"reason":string}\n'
                    'If unsure, return {"action":"done","reason":"..."}.\n'
                    "Never tap on keyboard keys; use type/keycode.\n"
                ),
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
        "response_format": {"type": "json_object"},
        "stop": ["```"],
    }

    with requests.Session() as sess:
        r = sess.post(
            url,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
            json=payload,
            timeout=timeout,
        )
    if not r.ok:
        raise RuntimeError(f"LLM HTTP {r.status_code}: {r.text[:2000]}")
    data = r.json()

    content = ""
    try:
        content = data["choices"][0]["message"].get("content") or ""
    except Exception:
        content = data.get("choices", [{}])[0].get("text") or ""

    return parse_llm_response(content)


def safe_action_from_error(err: Exception) -> Dict:
    return {"action": "done", "reason": f"LLM error: {err}"}


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


# ---------- main ----------


def main() -> int:
    parser = argparse.ArgumentParser(description="LLM-guided Android explorer (with guardrails)")
    parser.add_argument("--instruction", required=True, help="Goal for the agent")
    parser.add_argument("--xml", required=True, help="Path to uiautomator dump XML")
    parser.add_argument("--model", default=os.environ.get("LLM_MODEL", "local-model"))
    parser.add_argument("--limit", type=int, default=80, help="Max surfaced candidates")
    parser.add_argument("--no_llm", action="store_true", help="Only rule-based decisions (debug)")
    args = parser.parse_args()

    all_nodes, size, dominant_pkg = extract_candidates(args.xml)
    targets = parse_targets_from_instruction(args.instruction)
    phase = detect_phase(all_nodes)

    surfaced = surface_candidates(all_nodes, dominant_pkg, limit=args.limit)
    state_summary, state_json = build_state_summary(surfaced, size, phase, targets)

    log("State summary ready")
    log(state_summary)
    log("State JSON compact (debug):")
    log(json.dumps(compact_state(state_json), ensure_ascii=False))

    # Fast path to prevent obvious loops
    rb = rule_based_action(all_nodes, phase, targets)
    if rb:
        action = validate_action(rb, size)
        log(f"Rule-based action: {action}")
        print(json.dumps(action, ensure_ascii=False))
        return 0

    if args.no_llm:
        print(json.dumps({"action": "done", "reason": "Rule-based had no decision and --no_llm set"}, ensure_ascii=False))
        return 0

    prompt = build_prompt(args.instruction, state_summary, phase, targets)

    try:
        raw_action = call_llm(prompt, args.model)
    except Exception as e:
        print(json.dumps(safe_action_from_error(e), ensure_ascii=False))
        return 0

    log(f"Raw LLM response: {raw_action}")

    try:
        action = validate_action(raw_action, size)
    except Exception as e:
        warn(f"Action validation failed: {e}")
        action = {"action": "done", "reason": f"Invalid action from LLM: {e}", "x": None, "y": None, "text": "", "keycode": None}

    log(f"Validated action: {action}")
    print(json.dumps(action, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
