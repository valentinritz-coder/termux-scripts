#!/usr/bin/env python3
"""
LLM-driven Android UI explorer (CFL) - Trip Planner disciplined.

Pipeline:
1) Trip plan builder: instruction (text) -> trip_plan JSON persisted to --plan_file
2) UI executor: (trip_plan + compact UI state + history) -> exactly ONE action

Hard rules:
- LLM must NEVER invent x/y. For taps it must output target_idx from provided candidates.
- Exactly one action per run: tap | type | key | done
- Strict JSON output; validate and apply loop-breaker.

Works with:
- Home screen Trip Planner card (resource-id input_start/input_target/button_search)
- Trip Planner screen (desc "Select start"/"Select destination", SEARCH button)
- Navigation drawer (find clickable parent row containing "Trip Planner")
- Location picker (resource-id ...:id/input_location_name)
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


# ---------- helpers ----------

def _utc_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _norm(s: str) -> str:
    return (s or "").strip().lower()


def _norm_base(url: str) -> str:
    url = (url or "").rstrip("/")
    if url.endswith("/v1"):
        url = url[:-3]
    return url


def _chat_completions_url() -> str:
    base = _norm_base(os.getenv("OPENAI_BASE_URL", "http://127.0.0.1:8001"))
    return f"{base}/v1/chat/completions"


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


# ---------- history ----------

def load_history(path: str, limit: int = 10) -> List[Dict]:
    if not path or not os.path.exists(path):
        return []
    out: List[Dict] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                continue
    return out[-limit:]


def append_history(path: str, item: Dict) -> None:
    if not path:
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(item, ensure_ascii=False) + "\n")


def history_for_prompt(history: List[Dict], limit: int = 8) -> str:
    h = history[-limit:]
    lines: List[str] = []
    for it in h:
        act = it.get("action", {})
        lines.append(
            f"- ts={it.get('ts','?')} phase={it.get('phase','?')} sig={it.get('state_sig','?')} "
            f"action={act.get('action','?')} tidx={act.get('target_idx',None)} key={act.get('keycode',None)} "
            f"text={(act.get('text','') or '')[:24]} reason={(act.get('reason','') or '')[:80]}"
        )
    return "\n".join(lines) if lines else "(none)"


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
    rect: Optional[Tuple[int, int, int, int]]


def extract_candidates(xml_path: str) -> Tuple[List[Candidate], Dict[str, int], str]:
    tree = ET.parse(xml_path)
    root = tree.getroot()

    candidates: List[Candidate] = []
    max_x, max_y = 0, 0
    packages: List[str] = []

    for idx, node in enumerate(root.iter("node")):
        a = node.attrib
        bounds = a.get("bounds", "")
        rect = parse_bounds(bounds)
        center = None
        if rect:
            x1, y1, x2, y2 = rect
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
                rect=rect,
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
    scored.sort(key=lambda t: (t[0], -t[1]), reverse=True)
    out: List[Candidate] = []
    for _, _, c in scored:
        out.append(c)
        if len(out) >= limit:
            break
    return out


# ---------- phase detection ----------

def detect_phase(all_nodes: List[Candidate]) -> str:
    # Location picker
    picker_field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_location_name")), None)
    if picker_field:
        t = _norm(picker_field.text)
        if "start" in t:
            return "pick_start"
        if "destination" in t or "target" in t:
            return "pick_destination"
        return "pick_unknown"

    # Home trip planner card (resource ids exist)
    has_input_start = any("id/input_start" in c.resource_id for c in all_nodes)
    has_input_target = any("id/input_target" in c.resource_id for c in all_nodes)
    if has_input_start or has_input_target:
        return "journey_form"

    # Trip Planner page (desc fields)
    if any(_norm(c.content_desc) == "select start" for c in all_nodes) and any(
        _norm(c.content_desc) == "select destination" for c in all_nodes
    ):
        return "trip_planner"

    # Drawer open if it contains the usual menu texts
    drawer_texts = {"home", "trip planner", "departures", "my trips", "map", "tickets"}
    present = { _norm(c.text) for c in all_nodes if c.text }
    if len(drawer_texts.intersection(present)) >= 3:
        return "drawer"

    return "unknown"


# ---------- state + signature ----------

def compact_state(all_nodes: List[Candidate], size: Dict[str, int], phase: str, plan: Dict, max_candidates: int = 18, maxlen: int = 80) -> Dict:
    def clip(s: str) -> str:
        s = (s or "")
        return s if len(s) <= maxlen else s[: maxlen - 1] + "…"

    cands = []
    for c in all_nodes:
        if not (c.clickable and c.enabled):
            continue
        if is_ime_candidate(c):
            continue
        cands.append(
            {
                "idx": c.idx,
                "id": c.resource_id,
                "text": clip(c.text),
                "desc": clip(c.content_desc),
                "focused": bool(c.focused),
                "center": c.center,  # debug only
            }
        )

    # keep top scoring, but stable ordering
    # (we already surfaced; compact will be built from surfaced list in main)
    return {
        "phase": phase,
        "trip_plan": plan,
        "size": size,
        "candidates": cands[:max_candidates],
    }


def state_signature(compact: Dict) -> str:
    c = json.loads(json.dumps(compact))
    for cand in c.get("candidates", []):
        cand.pop("center", None)
    payload = json.dumps(c, ensure_ascii=False, sort_keys=True)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:12]


# ---------- trip plan builder ----------

def plan_from_instruction_regex(instruction: str) -> Dict:
    s = instruction or ""
    start = ""
    dest = ""

    m_all = list(re.finditer(r"([A-Za-zÀ-ÿ0-9' -]{2,})\s*(?:->|→)\s*([A-Za-zÀ-ÿ0-9' -]{2,})", s, flags=re.IGNORECASE))
    if m_all:
        m = m_all[-1]
        start = m.group(1).strip(" -\t\n")
        dest = m.group(2).strip(" -\t\n")
    else:
        m_all = list(re.finditer(r"entre\s+(.+?)\s+et\s+(.+?)(?:\s|$)", s, flags=re.IGNORECASE))
        if m_all:
            m = m_all[-1]
            start = m.group(1).strip(" -\t\n")
            dest = m.group(2).strip(" -\t\n")

    rail_only = bool(re.search(r"\btrain\b", s, flags=re.IGNORECASE)) and bool(re.search(r"\bonly\b|\buniquement\b", s, flags=re.IGNORECASE))
    no_via = bool(re.search(r"\bsans\s+via\b|\bno\s+via\b|\bwithout\s+via\b", s, flags=re.IGNORECASE))

    deny = []
    for mode in ["bus", "tram", "metro", "subway", "coach"]:
        if re.search(rf"\bpas\s+de\s+{mode}\b|\bno\s+{mode}\b|\bwithout\s+{mode}\b", s, flags=re.IGNORECASE):
            deny.append(mode)

    allowed_services = sorted(set(re.findall(r"\b(TGV|IC|TER|RE|RB)\b", s, flags=re.IGNORECASE))) or ["TGV", "IC", "TER", "RE", "RB"]

    when_mode = "now" if re.search(r"\bmaintenant\b|\bnow\b", s, flags=re.IGNORECASE) else "unspecified"

    return {
        "from": start,
        "to": dest,
        "via": None,
        "when": {"mode": when_mode},
        "constraints": {
            "rail_only": rail_only or bool(deny) or bool(allowed_services),
            "no_via": no_via,
            "deny_modes": deny,
            "allowed_services": [x.upper() for x in allowed_services],
        },
    }


def build_trip_plan(instruction: str, plan_file: str, model: str, allow_llm: bool) -> Dict:
    # If plan exists, trust it.
    if plan_file and os.path.exists(plan_file):
        try:
            with open(plan_file, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass

    # Base plan: regex fallback (always)
    plan = plan_from_instruction_regex(instruction)

    # Optional: ask LLM to refine trip plan (text -> JSON)
    # This is separate from the UI action LLM.
    if allow_llm:
        try:
            plan = call_llm_trip_parser(instruction, model, plan)
        except Exception as e:
            warn(f"Trip plan LLM parse failed, using regex plan: {e}")

    if plan_file:
        os.makedirs(os.path.dirname(plan_file) or ".", exist_ok=True)
        with open(plan_file, "w", encoding="utf-8") as f:
            json.dump(plan, f, ensure_ascii=False, indent=2)

    return plan


def call_llm_trip_parser(instruction: str, model: str, base_plan: Dict) -> Dict:
    url = _chat_completions_url()
    api_key = os.getenv("OPENAI_API_KEY", "dummy")
    timeout = float(os.getenv("OPENAI_TIMEOUT", "60"))

    prompt = textwrap.dedent(
        f"""
        Convert this instruction into a trip plan JSON.
        Instruction:
        {instruction}

        Start from this base plan and improve it if needed:
        {json.dumps(base_plan, ensure_ascii=False)}

        Output STRICT JSON only, same schema keys:
        {{
          "from": string,
          "to": string,
          "via": string|null,
          "when": {{"mode": "now|depart_at|arrive_by|unspecified", "datetime": string|null}},
          "constraints": {{
            "rail_only": boolean,
            "no_via": boolean,
            "deny_modes": [string],
            "allowed_services": [string]
          }}
        }}
        """
    ).strip()

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "Return ONLY one JSON object. No markdown. No comments."},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0,
        "max_tokens": 300,
        "stream": False,
        "response_format": {"type": "json_object"},
    }

    r = requests.post(
        url,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
        json=payload,
        timeout=timeout,
    )
    if not r.ok:
        raise RuntimeError(f"Trip parse HTTP {r.status_code}: {r.text[:400]}")

    data = r.json()
    content = data["choices"][0]["message"].get("content") or ""
    obj = parse_llm_response(content)
    return obj if isinstance(obj, dict) else base_plan


# ---------- drawer helpers ----------

def _rect_contains(outer: Optional[Tuple[int,int,int,int]], inner: Optional[Tuple[int,int,int,int]]) -> bool:
    if not outer or not inner:
        return False
    x1,y1,x2,y2 = outer
    a1,b1,a2,b2 = inner
    return x1 <= a1 and y1 <= b1 and x2 >= a2 and y2 >= b2


def find_clickable_parent_row_by_text(all_nodes: List[Candidate], text_exact: str) -> Optional[Candidate]:
    # find a text node with that label
    tnode = next((c for c in all_nodes if (c.text or "") == text_exact and c.rect), None)
    if not tnode:
        return None
    # find clickable parent-ish node enclosing its bounds
    parents = [
        c for c in all_nodes
        if c.clickable and c.enabled and c.center and _rect_contains(c.rect, tnode.rect)
    ]
    if not parents:
        return None
    # choose the tightest enclosing clickable rect (smallest area)
    def area(c: Candidate) -> int:
        x1,y1,x2,y2 = c.rect or (0,0,0,0)
        return max(1, (x2-x1)) * max(1, (y2-y1))
    parents.sort(key=lambda c: (area(c), c.idx))
    return parents[0]


# ---------- rule-based action ----------

def _contains_city(c: Candidate, city: str) -> bool:
    if not city:
        return False
    city_l = _norm(city)
    return (city_l in _norm(c.content_desc)) or (city_l == _norm(c.text)) or (city_l in _norm(c.text))


def rule_based_action(all_nodes: List[Candidate], phase: str, plan: Dict) -> Optional[Dict]:
    start = (plan.get("from") or "").strip()
    dest = (plan.get("to") or "").strip()

    # Drawer: tap Trip Planner entry (clickable parent row)
    if phase == "drawer":
        row = find_clickable_parent_row_by_text(all_nodes, "Trip Planner")
        if row:
            return {"action": "tap", "target_idx": row.idx, "reason": "Open Trip Planner from navigation drawer"}

    # Unknown: if burger present -> open drawer
    if phase == "unknown":
        burger = next((c for c in all_nodes if c.clickable and c.enabled and c.center and "navigation drawer" in _norm(c.content_desc)), None)
        if burger:
            return {"action": "tap", "target_idx": burger.idx, "reason": "Open navigation drawer"}
        # or if Trip Planner visible as card/button, tap it
        tp = next((c for c in all_nodes if c.clickable and c.enabled and c.center and _norm(c.text) == "trip planner"), None)
        if tp:
            return {"action": "tap", "target_idx": tp.idx, "reason": "Open Trip Planner"}

    # Home journey form (resource ids)
    if phase == "journey_form":
        start_field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_start")), None)
        dest_field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_target")), None)
        search_btn = next((c for c in all_nodes if c.resource_id.endswith(":id/button_search") or c.resource_id.endswith(":id/button_search_default")), None)

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

    # Trip Planner page (desc fields)
    if phase == "trip_planner":
        start_field = next((c for c in all_nodes if _norm(c.content_desc) == "select start" and c.clickable and c.enabled and c.center), None)
        dest_field = next((c for c in all_nodes if _norm(c.content_desc) == "select destination" and c.clickable and c.enabled and c.center), None)
        search_btn = next((c for c in all_nodes if c.resource_id.endswith(":id/button_search_default") and c.clickable and c.enabled and c.center), None)

        # For now: set start then destination, then search.
        if start_field and start:
            return {"action": "tap", "target_idx": start_field.idx, "reason": f"Open start field to set '{start}'"}
        if dest_field and dest:
            return {"action": "tap", "target_idx": dest_field.idx, "reason": f"Open destination field to set '{dest}'"}
        if search_btn:
            return {"action": "tap", "target_idx": search_btn.idx, "reason": "Launch search"}
        return None

    # Location picker
    if phase in {"pick_start", "pick_destination", "pick_unknown"}:
        want = start if phase == "pick_start" else dest if phase == "pick_destination" else (start or dest)

        # Prefer visible list entry that contains city
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

        field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_location_name") and c.center), None)
        if field and want:
            if field.focused:
                return {"action": "type", "text": want, "reason": f"Type '{want}' in location search field"}
            return {"action": "tap", "target_idx": field.idx, "reason": "Focus location input field"}

        if any(is_ime_candidate(c) for c in all_nodes):
            return {"action": "key", "keycode": 4, "reason": "Close keyboard overlay (BACK)"}

    return None


# ---------- LLM executor ----------

def build_prompt(instruction: str, compact: Dict, history_text: str, state_sig: str) -> str:
    return textwrap.dedent(
        f"""
        You control an Android app using adb + uiautomator.
        Your job is deterministic progress, not creativity.

        OBJECTIVE (user intent):
        {instruction}

        TRIP PLAN (truth to execute):
        {json.dumps(compact.get("trip_plan", {}), ensure_ascii=False)}

        LOOP AVOIDANCE (MANDATORY):
        - Current UI state signature: {state_sig}
        - If last history item has SAME state_sig, do NOT repeat the same action on the same target_idx.
        - If you already tapped a field and nothing changed, next step should be type (if applicable) or BACK.

        OUTPUT: STRICT JSON only (no extra keys, no schema echoing):
        {{
          "action": "tap" | "type" | "key" | "done",
          "target_idx": number | null,
          "text": string,
          "keycode": number | null,
          "reason": string
        }}

        RULES:
        - For tap: you MUST choose target_idx from UI STATE candidates list.
        - Never tap keyboard/IME keys. Use type or BACK (keycode=4).
        - Choose exactly ONE action.

        RECENT HISTORY:
        {history_text}

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


def call_llm_action(prompt: str, model: str) -> Dict:
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
                    "action must be exactly one of: tap,type,key,done.\n"
                    "For tap: choose target_idx from candidates.\n"
                    "Never output a schema example.\n"
                ),
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
        "response_format": {"type": "json_object"},
    }

    r = requests.post(
        url,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
        json=payload,
        timeout=timeout,
    )
    if not r.ok:
        raise RuntimeError(f"LLM HTTP {r.status_code}: {r.text[:800]}")
    data = r.json()

    content = data["choices"][0]["message"].get("content") or ""
    return parse_llm_response(content)


# ---------- validation + loop breaker ----------

def _index_by_idx(surfaced: List[Candidate]) -> Dict[int, Candidate]:
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
            raise ValueError("Tap requires target_idx")
        tidx = int(action.get("target_idx"))
        c = surfaced_by_idx.get(tidx)
        if c is None:
            raise ValueError(f"target_idx={tidx} not in surfaced list")
        if not (c.clickable and c.enabled):
            raise ValueError(f"target_idx={tidx} not clickable+enabled")
        if c.center is None:
            raise ValueError(f"target_idx={tidx} missing center")
        if is_ime_candidate(c):
            raise ValueError("Refusing to tap IME element")

        x, y = c.center
        max_x = max(1, int(size.get("width", 1080)))
        max_y = max(1, int(size.get("height", 2400)))
        if x <= 0 or y <= 0 or x > max_x or y > max_y:
            raise ValueError("Tap outside screen bounds")

        safe["target_idx"] = tidx
        safe["x"], safe["y"] = x, y

    elif act == "type":
        txt = action.get("text")
        if txt is None:
            raise ValueError("Type action missing text")
        safe["text"] = str(txt)

    elif act == "key":
        if action.get("keycode", None) is None:
            raise ValueError("Key action missing keycode")
        safe["keycode"] = int(action.get("keycode"))

    return safe


def is_repeat_loop(hist: List[Dict], sig: str, action: Dict) -> bool:
    if not hist:
        return False
    last = hist[-1]
    if last.get("state_sig") != sig:
        return False
    last_act = last.get("action", {})
    return (
        last_act.get("action") == action.get("action")
        and last_act.get("target_idx") == action.get("target_idx")
        and last_act.get("keycode") == action.get("keycode")
        and (last_act.get("text","") == action.get("text",""))
    )


# ---------- main ----------

def main() -> int:
    parser = argparse.ArgumentParser(description="LLM-guided CFL Trip Planner (disciplined)")
    parser.add_argument("--instruction", required=True)
    parser.add_argument("--xml", required=True)
    parser.add_argument("--model", default=os.environ.get("LLM_MODEL", "local-model"))
    parser.add_argument("--limit", type=int, default=90)
    parser.add_argument("--no_llm", action="store_true")
    parser.add_argument("--history_file", default=os.environ.get("LLM_HISTORY_FILE", ""))
    parser.add_argument("--history_limit", type=int, default=int(os.environ.get("LLM_HISTORY_LIMIT", "10")))
    parser.add_argument("--plan_file", default=os.environ.get("LLM_PLAN_FILE", ""))
    parser.add_argument("--plan_with_llm", action="store_true", help="Let LLM refine trip plan JSON once (optional)")
    args = parser.parse_args()

    plan = build_trip_plan(args.instruction, args.plan_file, args.model, allow_llm=args.plan_with_llm)

    all_nodes, size, dominant_pkg = extract_candidates(args.xml)
    phase = detect_phase(all_nodes)

    surfaced = surface_candidates(all_nodes, dominant_pkg, limit=args.limit)
    surfaced_by_idx = _index_by_idx(surfaced)

    # Compact state for prompt (built from surfaced list for relevance)
    compact = compact_state(surfaced, size, phase, plan)
    sig = state_signature(compact)

    hist = load_history(args.history_file, limit=args.history_limit)
    hist_text = history_for_prompt(hist)

    log("Compact state (LLM input):")
    log(json.dumps(compact, ensure_ascii=False, indent=2))

    # Rule-based first (fast + robust)
    rb = rule_based_action(all_nodes, phase, plan)
    if rb:
        action = validate_action(rb, size, surfaced_by_idx)
        if is_repeat_loop(hist, sig, action):
            warn("Repeat-loop detected on identical state_sig; forcing BACK.")
            action = {"action": "key", "target_idx": None, "x": None, "y": None, "text": "", "keycode": 4, "reason": "Loop breaker: BACK"}

        append_history(
            args.history_file,
            {
                "ts": _utc_iso(),
                "phase": phase,
                "state_sig": sig,
                "instruction": args.instruction[:200],
                "action": {
                    "action": action.get("action"),
                    "target_idx": action.get("target_idx"),
                    "keycode": action.get("keycode"),
                    "text": action.get("text", ""),
                    "reason": action.get("reason", ""),
                },
            },
        )

        log(f"Rule-based action: {action}")
        print(json.dumps(action, ensure_ascii=False))
        return 0

    if args.no_llm:
        action = {"action": "done", "reason": "No rule-based decision and --no_llm set", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}
        print(json.dumps(action, ensure_ascii=False))
        return 0

    prompt = build_prompt(args.instruction, compact, hist_text, sig)

    # LLM fallback
    try:
        raw = call_llm_action(prompt, args.model)
        log(f"Raw LLM response: {raw}")
        action = validate_action(raw, size, surfaced_by_idx)
    except Exception as e:
        warn(f"LLM/validation failed: {e}")
        # Safer fallback than "done": BACK to escape overlays / bad states
        action = {"action": "key", "target_idx": None, "x": None, "y": None, "text": "", "keycode": 4, "reason": f"Fallback BACK after LLM failure: {e}"}

    if is_repeat_loop(hist, sig, action):
        warn("Repeat-loop detected on identical state_sig; forcing BACK.")
        action = {"action": "key", "target_idx": None, "x": None, "y": None, "text": "", "keycode": 4, "reason": "Loop breaker: BACK"}

    append_history(
        args.history_file,
        {
            "ts": _utc_iso(),
            "phase": phase,
            "state_sig": sig,
            "instruction": args.instruction[:200],
            "action": {
                "action": action.get("action"),
                "target_idx": action.get("target_idx"),
                "keycode": action.get("keycode"),
                "text": action.get("text", ""),
                "reason": action.get("reason", ""),
            },
        },
    )

    log(f"Validated action: {action}")
    print(json.dumps(action, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
