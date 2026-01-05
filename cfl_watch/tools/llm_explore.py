#!/usr/bin/env python3
"""
LLM-driven Android UI explorer (CFL) with guardrails.

Discipline upgrades (the point):
- Objective + constraints + state are always provided.
- The LLM MUST choose targets from the provided state using `target_idx` (no hallucinated x/y).
- Exactly ONE action per run (tap OR type OR key OR done).
- Strict JSON output (enforced with response_format=json_object + validation).
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


# ---------- state + phase + constraints ----------


def _norm(s: str) -> str:
    return (s or "").strip().lower()


def parse_targets_from_instruction(instruction: str) -> Dict[str, str]:
    """
    Tries to find something like "Luxembourg -> Arlon" in a noisy instruction.
    Returns {"start": "...", "destination": "..."} when possible.
    """
    s = instruction or ""
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


def parse_constraints_from_instruction(instruction: str) -> Dict:
    """
    Pulls common constraints from the instruction.
    You can keep this simple and still win big:
    - no_via: "sans via"
    - exclude: bus/tram
    - allowed_services: TGV/IC/TER/RE/RB if mentioned (otherwise default)
    """
    s = _norm(instruction)
    no_via = bool(re.search(r"\bsans\s+via\b|\bwithout\s+via\b|\bno\s+via\b", s))

    exclude = []
    for mode in ["bus", "tram", "metro", "subway", "coach"]:
        if re.search(rf"\bpas\s+de\s+{mode}\b|\bno\s+{mode}\b|\bwithout\s+{mode}\b|\bexclude\s+{mode}\b", s):
            exclude.append(mode)

    allowed_services = sorted(set(re.findall(r"\b(TGV|IC|TER|RE|RB)\b", instruction, flags=re.IGNORECASE)))
    if not allowed_services:
        allowed_services = ["TGV", "IC", "TER", "RE", "RB"]

    return {
        "no_via": no_via,
        "exclude_modes": exclude,  # informational for now
        "allowed_services": [x.upper() for x in allowed_services],
        "rail_only": True if ("bus" in exclude or "tram" in exclude or allowed_services) else False,
    }


def detect_phase(all_nodes: List[Candidate]) -> str:
    """
    Coarse phase detection:
    - "journey_form": CFL journey form with input_start/input_target
    - "pick_start": location picker currently selecting start
    - "pick_destination": location picker currently selecting destination
    - "pick_unknown": location picker but unclear which field
    - "unknown": anything else
    """
    has_input_start = any("id/input_start" in c.resource_id for c in all_nodes)
    has_input_target = any("id/input_target" in c.resource_id for c in all_nodes)
    if has_input_start or has_input_target:
        return "journey_form"

    picker_field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_location_name")), None)
    if picker_field:
        t = _norm(picker_field.text)
        if "start" in t:
            return "pick_start"
        if "destination" in t or "target" in t:
            return "pick_destination"
        return "pick_unknown"

    return "unknown"


def is_ime_candidate(c: Candidate) -> bool:
    """
    Keyboard keys are poison for an automation planner.
    """
    pkg = _norm(c.package)
    if "inputmethod" in pkg or "keyboard" in pkg:
        return True

    txt = (c.text or "").strip()
    if txt in {"ESC", "ALT", "CTRL", "HOME", "END", "PGUP", "PGDN", "↹", "⇳", "☰", "↑", "↓", "←", "→"}:
        return True

    return False


def score_candidate(c: Candidate, dominant_pkg: str) -> int:
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
        s -= 200
    return s


def surface_candidates(all_nodes: List[Candidate], dominant_pkg: str, limit: int) -> List[Candidate]:
    scored = [(score_candidate(c, dominant_pkg), c.idx, c) for c in all_nodes]
    scored.sort(key=lambda t: (t[0], -t[1]), reverse=True)
    out: List[Candidate] = []
    for _, _, c in scored:
        out.append(c)
        if len(out) >= limit:
            break
    return out


def build_state(surfaced: List[Candidate], size: Dict[str, int], phase: str, targets: Dict[str, str], constraints: Dict) -> Dict:
    return {
        "phase": phase,
        "targets": targets,
        "constraints": constraints,
        "size": size,
        "candidates": [c.__dict__ for c in surfaced],
    }


def compact_state(state: Dict, max_candidates: int = 18, maxlen: int = 80) -> Dict:
    def clip(s: str) -> str:
        s = (s or "")
        return s if len(s) <= maxlen else s[: maxlen - 1] + "…"

    out = []
    for c in state.get("candidates", []):
        # keep only actionable things: clickable+enabled and non-IME
        if c.get("clickable") and c.get("enabled") and not is_ime_candidate(
            Candidate(
                idx=c.get("idx", -1),
                package=c.get("package", ""),
                class_name=c.get("class_name", ""),
                resource_id=c.get("resource_id", ""),
                text=c.get("text", ""),
                content_desc=c.get("content_desc", ""),
                clickable=bool(c.get("clickable")),
                enabled=bool(c.get("enabled")),
                focusable=bool(c.get("focusable")),
                focused=bool(c.get("focused")),
                bounds=c.get("bounds", ""),
                center=c.get("center"),
            )
        ):
            out.append(
                {
                    "idx": c.get("idx"),
                    "id": c.get("resource_id", ""),
                    "text": clip(c.get("text", "")),
                    "desc": clip(c.get("content_desc", "")),
                    "focused": bool(c.get("focused")),
                    "center": c.get("center"),  # not for the LLM to invent; just for debug parity
                }
            )

    return {
        "phase": state.get("phase", ""),
        "targets": state.get("targets", {}),
        "constraints": state.get("constraints", {}),
        "size": state.get("size", {}),
        "candidates": out[:max_candidates],
    }


# ---------- rule-based “fast path” (still allowed, still disciplined) ----------


def _contains_city(c: Candidate, city: str) -> bool:
    if not city:
        return False
    city_l = _norm(city)
    text = _norm(c.text)
    desc = _norm(c.content_desc)
    return (city_l in desc) or (city_l == text) or (city_l in text)


def _find_nav_itinerary(all_nodes: List[Candidate]) -> Optional[Candidate]:
    needles = ["itinéraire", "itinerary", "trajet", "journey", "recherche", "search"]
    candidates = []
    for c in all_nodes:
        if not (c.clickable and c.enabled and c.center):
            continue
        blob = f"{_norm(c.text)} {_norm(c.content_desc)} {_norm(c.resource_id)}"
        if any(n in blob for n in needles):
            candidates.append(c)
    if not candidates:
        return None
    candidates.sort(key=lambda x: (len((x.text or "") + (x.content_desc or "")), x.idx), reverse=True)
    return candidates[0]


def rule_based_action(all_nodes: List[Candidate], phase: str, targets: Dict[str, str]) -> Optional[Dict]:
    start = targets.get("start", "").strip()
    dest = targets.get("destination", "").strip()

    if phase == "unknown":
        nav = _find_nav_itinerary(all_nodes)
        if nav:
            return {"action": "tap", "target_idx": nav.idx, "reason": "Navigate to itinerary/search screen"}

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
            return {"action": "tap", "target_idx": start_field.idx, "reason": f"Open start field to set '{start}'"}
        if dest_field and dest and is_placeholder(dest_field.text) and dest_field.center:
            return {"action": "tap", "target_idx": dest_field.idx, "reason": f"Open destination field to set '{dest}'"}
        if search_btn and search_btn.center:
            return {"action": "tap", "target_idx": search_btn.idx, "reason": "Launch search"}

        return None

    if phase in {"pick_start", "pick_destination", "pick_unknown"}:
        want = start if phase == "pick_start" else dest if phase == "pick_destination" else (start or dest)

        list_entries = [
            c
            for c in all_nodes
            if c.clickable
            and c.enabled
            and c.center
            and not c.resource_id.endswith(":id/button_favorite")
            and not c.resource_id.endswith(":id/button_location_voice")
        ]

        matching = [c for c in list_entries if _contains_city(c, want)]
        if want and matching:
            matching.sort(key=lambda c: (len((c.content_desc or "").strip()), c.idx), reverse=True)
            best = matching[0]
            return {"action": "tap", "target_idx": best.idx, "reason": f"Select '{want}' from visible list"}

        field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_location_name")), None)
        if field and field.center and want:
            if field.focused:
                return {"action": "type", "text": want, "reason": f"Type '{want}' in location search field"}
            return {"action": "tap", "target_idx": field.idx, "reason": "Focus location input field"}

        if any(is_ime_candidate(c) for c in all_nodes):
            return {"action": "key", "keycode": 4, "reason": "Close keyboard overlay (BACK)"}

        return None

    return None


# ---------- prompt + LLM ----------


def build_prompt(instruction: str, compact: Dict) -> str:
    """
    LLM sees:
    - objective + constraints (from instruction + parsed constraints)
    - UI state (compact JSON)
    It must pick ONE action, and for taps MUST pick target_idx from the candidate list.
    """
    return textwrap.dedent(
        f"""
        You are controlling an Android app using adb + uiautomator.
        Your job is NOT to be clever. Your job is to be deterministic and state-driven.

        OBJECTIVE:
        {instruction}

        CONSTRAINTS (must respect):
        - Use the provided UI state only. Do not invent buttons or coordinates.
        - Exactly ONE action this turn.
        - For taps: you MUST choose target_idx from state.candidates[].idx (no raw x/y).
        - Never tap on keyboard keys (ESC/ALT/CTRL/etc). Use action=type or action=key.
        - If typing is needed but the field is not focused: tap the input field first (and type next turn).

        OUTPUT: return STRICT JSON only (no markdown), schema:
        {{
          "action": "tap|type|key|done",
          "target_idx": number|null,
          "text": string,
          "keycode": number|null,
          "reason": string
        }}

        UI STATE (compact JSON):
        {json.dumps(compact, ensure_ascii=False)}

        Decide the next single action now.
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
    max_tokens = int(os.getenv("LLM_MAX_TOKENS", "192"))
    temperature = float(os.getenv("LLM_TEMPERATURE", "0"))

    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are an automation planner.\n"
                    "Return ONLY one JSON object.\n"
                    "No markdown.\n"
                    "Must be state-driven.\n"
                    "For taps: select a target_idx that exists in the provided candidate list.\n"
                    'Schema: {"action":"tap|type|key|done","target_idx":number|null,"text":string,"keycode":number|null,"reason":string}\n'
                    "Never tap keyboard keys.\n"
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
    return {"action": "done", "reason": f"LLM error: {err}", "target_idx": None, "text": "", "keycode": None}


def _index_surfaced_by_idx(surfaced: List[Candidate]) -> Dict[int, Candidate]:
    return {c.idx: c for c in surfaced}


def validate_action(action: Dict, size: Dict[str, int], surfaced_by_idx: Dict[int, Candidate]) -> Dict:
    allowed = {"tap", "type", "key", "done"}
    act = str(action.get("action", "")).strip().lower()
    if act not in allowed:
        raise ValueError(f"Invalid action: {act}")

    safe = {
        "action": act,
        "target_idx": None,
        "x": None,
        "y": None,
        "text": "",
        "keycode": None,
        "reason": (action.get("reason") or "").strip(),
    }

    if act == "tap":
        # disciplined: target_idx must exist in surfaced candidates
        if action.get("target_idx", None) is None:
            raise ValueError("Tap requires target_idx (selected from state.candidates[].idx)")

        try:
            tidx = int(action.get("target_idx"))
        except Exception as exc:
            raise ValueError("Tap requires numeric target_idx") from exc

        c = surfaced_by_idx.get(tidx)
        if c is None:
            raise ValueError(f"target_idx={tidx} is not in the surfaced candidate list")
        if not (c.clickable and c.enabled):
            raise ValueError(f"target_idx={tidx} is not clickable+enabled")
        if c.center is None:
            raise ValueError(f"target_idx={tidx} has no center (missing bounds?)")
        if is_ime_candidate(c):
            raise ValueError("Refusing to tap IME/keyboard element")

        x, y = c.center
        max_x = max(1, int(size.get("width", 1080)))
        max_y = max(1, int(size.get("height", 2400)))
        if x <= 0 or y <= 0 or x > max_x or y > max_y:
            raise ValueError("Tap coordinates outside screen bounds")

        safe["target_idx"] = tidx
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
    parser = argparse.ArgumentParser(description="LLM-guided Android explorer (disciplined, state-driven)")
    parser.add_argument("--instruction", required=True, help="Goal for the agent")
    parser.add_argument("--xml", required=True, help="Path to uiautomator dump XML")
    parser.add_argument("--model", default=os.environ.get("LLM_MODEL", "local-model"))
    parser.add_argument("--limit", type=int, default=90, help="Max surfaced candidates")
    parser.add_argument("--no_llm", action="store_true", help="Only rule-based decisions (debug)")
    args = parser.parse_args()

    all_nodes, size, dominant_pkg = extract_candidates(args.xml)
    targets = parse_targets_from_instruction(args.instruction)
    constraints = parse_constraints_from_instruction(args.instruction)
    phase = detect_phase(all_nodes)

    surfaced = surface_candidates(all_nodes, dominant_pkg, limit=args.limit)
    state = build_state(surfaced, size, phase, targets, constraints)
    compact = compact_state(state)

    log("Compact state (what the LLM actually gets):")
    log(json.dumps(compact, ensure_ascii=False, indent=2))

    surfaced_by_idx = _index_surfaced_by_idx(surfaced)

    # rule-based fast path (still outputs disciplined schema)
    rb = rule_based_action(all_nodes, phase, targets)
    if rb:
        action = validate_action(rb, size, surfaced_by_idx)
        log(f"Rule-based action: {action}")
        print(json.dumps(action, ensure_ascii=False))
        return 0

    if args.no_llm:
        print(json.dumps({"action": "done", "reason": "Rule-based had no decision and --no_llm set", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}, ensure_ascii=False))
        return 0

    prompt = build_prompt(args.instruction, compact)

    try:
        raw_action = call_llm(prompt, args.model)
    except Exception as e:
        print(json.dumps(safe_action_from_error(e), ensure_ascii=False))
        return 0

    log(f"Raw LLM response: {raw_action}")

    try:
        action = validate_action(raw_action, size, surfaced_by_idx)
    except Exception as e:
        warn(f"Action validation failed: {e}")
        action = {"action": "done", "reason": f"Invalid action from LLM: {e}", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}

    log(f"Validated action: {action}")
    print(json.dumps(action, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
