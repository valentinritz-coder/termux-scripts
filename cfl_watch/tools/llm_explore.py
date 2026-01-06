#!/usr/bin/env python3
"""
LLM-driven Android UI explorer (CFL) with guardrails.

Discipline upgrades:
- Objective + constraints + state are always provided.
- The LLM MUST choose tap targets from state using `target_idx` (no hallucinated x/y).
- Exactly ONE action per run (tap OR type OR key OR done).
- Strict JSON output (response_format=json_object + validation).
- History JSONL + state signature loop breaker.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import re
import sys
import textwrap
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
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


# ---------- history ----------

def _utc_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def load_history(path: str, limit: int = 10) -> List[Dict]:
    if not path or not os.path.exists(path):
        return []
    items: List[Dict] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                items.append(json.loads(line))
            except Exception:
                continue
    return items[-limit:]


def append_history(path: str, item: Dict) -> None:
    if not path:
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(item, ensure_ascii=False) + "\n")


def history_for_prompt(history: List[Dict], limit: int = 8) -> str:
    h = history[-limit:]
    if not h:
        return "(none)"
    lines = []
    for it in h:
        act = it.get("action", {}) or {}
        lines.append(
            f"- ts={it.get('ts','?')} phase={it.get('phase','?')} sig={it.get('state_sig','?')} "
            f"action={act.get('action','?')} tidx={act.get('target_idx',None)} "
            f"key={act.get('keycode',None)} text={(act.get('text','') or '')[:24]} "
            f"reason={(act.get('reason','') or '')[:70]}"
        )
    return "\n".join(lines)


def is_repeat_loop(hist: List[Dict], sig: str, action: Dict) -> bool:
    if not hist:
        return False
    last = hist[-1]
    if last.get("state_sig") != sig:
        return False
    last_act = last.get("action", {}) or {}
    return (
        last_act.get("action") == action.get("action")
        and last_act.get("target_idx") == action.get("target_idx")
        and last_act.get("keycode") == action.get("keycode")
        and (last_act.get("text", "") == action.get("text", ""))
    )


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


def _norm(s: str) -> str:
    return (s or "").strip().lower()


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

        enabled = a.get("enabled", "").strip().lower() != "false"

        candidates.append(
            Candidate(
                idx=idx,
                package=pkg,
                class_name=a.get("class", ""),
                resource_id=a.get("resource-id", ""),
                text=a.get("text", ""),
                content_desc=a.get("content-desc", ""),
                clickable=_bool_attr(a.get("clickable"), default=False),
                enabled=enabled,
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

    dominant_pkg = Counter(packages).most_common(1)[0][0] if packages else ""
    return candidates, size, dominant_pkg


# ---------- phase + constraints + target parsing ----------

def parse_targets_from_instruction(instruction: str) -> Dict[str, str]:
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
    s = _norm(instruction)

    no_via = bool(re.search(r"\bsans\s+via\b|\bwithout\s+via\b|\bno\s+via\b", s))

    exclude = []
    for mode in ["bus", "tram", "metro", "subway", "coach"]:
        if re.search(rf"\bpas\s+de\s+{mode}\b|\bno\s+{mode}\b|\bwithout\s+{mode}\b|\bexclude\s+{mode}\b", s):
            exclude.append(mode)

    mentioned_services = sorted(set(re.findall(r"\b(TGV|IC|TER|RE|RB)\b", instruction, flags=re.IGNORECASE)))
    allowed_services = [x.upper() for x in (mentioned_services or ["TGV", "IC", "TER", "RE", "RB"])]

    # rail_only should reflect what user asked, not defaults
    rail_only = bool(exclude) or bool(mentioned_services) or ("train" in s) or ("rail" in s)

    return {
        "no_via": no_via,
        "exclude_modes": exclude,
        "allowed_services": allowed_services,
        "rail_only": rail_only,
    }


def detect_phase(all_nodes: List[Candidate]) -> str:
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


# ---------- candidate filtering/scoring ----------

def is_ime_candidate(c: Candidate) -> bool:
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
    scored.sort(key=lambda t: (-t[0], t[1]))  # high score first, stable by idx
    return [c for _, _, c in scored[:limit]]


def build_state(
    surfaced: List[Candidate],
    size: Dict[str, int],
    phase: str,
    targets: Dict[str, str],
    constraints: Dict,
) -> Dict:
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

    compact_candidates = []
    for c in state.get("candidates", []):
        if not (c.get("clickable") and c.get("enabled")):
            continue

        tmp = Candidate(
            idx=int(c.get("idx", -1)),
            package=c.get("package", "") or "",
            class_name=c.get("class_name", "") or "",
            resource_id=c.get("resource_id", "") or "",
            text=c.get("text", "") or "",
            content_desc=c.get("content_desc", "") or "",
            clickable=bool(c.get("clickable")),
            enabled=bool(c.get("enabled")),
            focusable=bool(c.get("focusable")),
            focused=bool(c.get("focused")),
            bounds=c.get("bounds", "") or "",
            center=c.get("center"),
        )
        if is_ime_candidate(tmp):
            continue

        compact_candidates.append(
            {
                "idx": tmp.idx,
                "id": tmp.resource_id,
                "text": clip(tmp.text),
                "desc": clip(tmp.content_desc),
                "focused": tmp.focused,
                "center": tmp.center,  # debug only; LLM must NEVER invent coordinates
            }
        )

    return {
        "phase": state.get("phase", ""),
        "targets": state.get("targets", {}),
        "constraints": state.get("constraints", {}),
        "size": state.get("size", {}),
        "candidates": compact_candidates[:max_candidates],
    }


def state_signature(compact: Dict) -> str:
    c = json.loads(json.dumps(compact))  # deep copy
    for cand in c.get("candidates", []):
        cand.pop("center", None)  # remove shaky coords
    payload = json.dumps(c, ensure_ascii=False, sort_keys=True)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:12]


# ---------- rule-based fast path (disciplined) ----------

def _contains_city(c: Candidate, city: str) -> bool:
    if not city:
        return False
    city_l = _norm(city)
    return (city_l in _norm(c.content_desc)) or (city_l == _norm(c.text)) or (city_l in _norm(c.text))


def _find_nav_itinerary(all_nodes: List[Candidate]) -> Optional[Candidate]:
    needles = ["itinéraire", "itinerary", "trajet", "journey", "recherche", "search"]
    hits = []
    for c in all_nodes:
        if not (c.clickable and c.enabled and c.center):
            continue
        blob = f"{_norm(c.text)} {_norm(c.content_desc)} {_norm(c.resource_id)}"
        if any(n in blob for n in needles):
            hits.append(c)
    if not hits:
        return None
    hits.sort(key=lambda x: (len((x.text or "") + (x.content_desc or "")), x.idx), reverse=True)
    return hits[0]


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
            return (t == "") or ("select" in t)

        if start_field and start and is_placeholder(start_field.text) and start_field.center:
            return {"action": "tap", "target_idx": start_field.idx, "reason": f"Open start field to set '{start}'"}
        if dest_field and dest and is_placeholder(dest_field.text) and dest_field.center:
            return {"action": "tap", "target_idx": dest_field.idx, "reason": f"Open destination field to set '{dest}'"}
        if search_btn and search_btn.center:
            return {"action": "tap", "target_idx": search_btn.idx, "reason": "Launch search"}

    if phase in {"pick_start", "pick_destination", "pick_unknown"}:
        want = start if phase == "pick_start" else dest if phase == "pick_destination" else (start or dest)

        list_entries = [
            c for c in all_nodes
            if c.clickable and c.enabled and c.center
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


# ---------- LLM prompt + call ----------

def build_prompt(instruction: str, compact: Dict, history_text: str, state_sig: str) -> str:
    return textwrap.dedent(
        f"""
        You control an Android app via adb + uiautomator.
        Your job is deterministic progress, not creativity.

        OBJECTIVE:
        {instruction}

        HARD RULES:
        - Output MUST be a single JSON object only (no markdown).
        - If action is "tap": you MUST pick target_idx from UI_STATE.candidates[].idx.
        - NEVER invent x/y. NEVER tap keyboard keys.
        - If state_sig is unchanged from the previous step, DO NOT repeat the same action on the same target_idx.
        - If you tapped an input field last step and state_sig is unchanged: next action should be "type" (if appropriate) or "key" BACK.

        THIS TURN state_sig: {state_sig}

        OUTPUT SCHEMA:
        {{
          "action": "tap|type|key|done",
          "target_idx": number|null,
          "text": string,
          "keycode": number|null,
          "reason": string
        }}

        RECENT HISTORY:
        {history_text}

        UI_STATE (compact JSON):
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
                    'Schema: {"action":"tap|type|key|done","target_idx":number|null,"text":string,"keycode":number|null,"reason":string}\n'
                    "For taps: target_idx MUST be from the provided candidate list.\n"
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


# ---------- validation ----------

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
        if action.get("target_idx", None) is None:
            raise ValueError("Tap requires target_idx (selected from UI_STATE.candidates[].idx)")
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
        txt = str(txt)
        if txt.strip() == "":
            raise ValueError("Type action text must be non-empty")
        safe["text"] = txt

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
    parser.add_argument("--history_file", default=os.environ.get("LLM_HISTORY_FILE", ""), help="Path to history JSONL")
    parser.add_argument("--history_limit", type=int, default=int(os.environ.get("LLM_HISTORY_LIMIT", "10")))
    args = parser.parse_args()

    all_nodes, size, dominant_pkg = extract_candidates(args.xml)

    targets = parse_targets_from_instruction(args.instruction)
    constraints = parse_constraints_from_instruction(args.instruction)
    phase = detect_phase(all_nodes)

    surfaced = surface_candidates(all_nodes, dominant_pkg, limit=args.limit)
    surfaced_by_idx = _index_surfaced_by_idx(surfaced)

    state = build_state(surfaced, size, phase, targets, constraints)
    compact = compact_state(state)
    sig = state_signature(compact)

    hist = load_history(args.history_file, limit=args.history_limit)
    hist_text = history_for_prompt(hist)

    log("Compact state (what the LLM actually gets):")
    log(json.dumps(compact, ensure_ascii=False, indent=2))
    log(f"state_sig={sig}")

    final_action: Dict

    # --- rule-based first
    rb = rule_based_action(all_nodes, phase, targets)
    if rb is not None:
        try:
            final_action = validate_action(rb, size, surfaced_by_idx)
        except Exception as e:
            warn(f"Rule-based action invalid: {e}")
            final_action = {"action": "done", "reason": f"Rule-based invalid: {e}", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}

        if is_repeat_loop(hist, sig, final_action):
            warn("Detected repeat-loop on identical state_sig; forcing BACK.")
            final_action = {"action": "key", "target_idx": None, "x": None, "y": None, "text": "", "keycode": 4, "reason": "Loop breaker: BACK"}

        append_history(
            args.history_file,
            {
                "ts": _utc_iso(),
                "phase": phase,
                "state_sig": sig,
                "instruction": args.instruction[:200],
                "action": {
                    "action": final_action.get("action"),
                    "target_idx": final_action.get("target_idx"),
                    "keycode": final_action.get("keycode"),
                    "text": final_action.get("text", ""),
                    "reason": final_action.get("reason", ""),
                },
            },
        )

        print(json.dumps(final_action, ensure_ascii=False))
        return 0

    if args.no_llm:
        final_action = {"action": "done", "reason": "Rule-based had no decision and --no_llm set", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}
        append_history(
            args.history_file,
            {
                "ts": _utc_iso(),
                "phase": phase,
                "state_sig": sig,
                "instruction": args.instruction[:200],
                "action": {
                    "action": final_action.get("action"),
                    "target_idx": None,
                    "keycode": None,
                    "text": "",
                    "reason": final_action.get("reason", ""),
                },
            },
        )
        print(json.dumps(final_action, ensure_ascii=False))
        return 0

    # --- LLM fallback
    prompt = build_prompt(args.instruction, compact, hist_text, sig)

    try:
        raw_action = call_llm(prompt, args.model)
    except Exception as e:
        final_action = safe_action_from_error(e)
        append_history(
            args.history_file,
            {
                "ts": _utc_iso(),
                "phase": phase,
                "state_sig": sig,
                "instruction": args.instruction[:200],
                "action": {
                    "action": final_action.get("action"),
                    "target_idx": None,
                    "keycode": None,
                    "text": "",
                    "reason": final_action.get("reason", ""),
                },
            },
        )
        print(json.dumps(final_action, ensure_ascii=False))
        return 0

    log(f"Raw LLM response: {raw_action}")

    try:
        final_action = validate_action(raw_action, size, surfaced_by_idx)
    except Exception as e:
        warn(f"Action validation failed: {e}")
        final_action = {"action": "done", "reason": f"Invalid action from LLM: {e}", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}

    if is_repeat_loop(hist, sig, final_action):
        warn("Detected repeat-loop on identical state_sig; forcing BACK.")
        final_action = {"action": "key", "target_idx": None, "x": None, "y": None, "text": "", "keycode": 4, "reason": "Loop breaker: BACK"}

    append_history(
        args.history_file,
        {
            "ts": _utc_iso(),
            "phase": phase,
            "state_sig": sig,
            "instruction": args.instruction[:200],
            "action": {
                "action": final_action.get("action"),
                "target_idx": final_action.get("target_idx"),
                "keycode": final_action.get("keycode"),
                "text": final_action.get("text", ""),
                "reason": final_action.get("reason", ""),
            },
        },
    )

    log(f"Validated action: {final_action}")
    print(json.dumps(final_action, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
