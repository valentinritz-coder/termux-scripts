#!/usr/bin/env python3
"""
LLM-driven Android UI explorer (CFL Trip Planner) with guardrails.

Goal:
- Objective + constraints + UI state provided every step
- LLM must pick a target_idx from the provided compact state (no invented x/y)
- Exactly ONE action per run: tap OR type OR key OR done
- Strict JSON output (response_format=json_object) + validation
- Rule-based fast paths for common CFL screens (home, drawer, trip planner, picker, dialogs)
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


BOUNDS_RE = re.compile(r"\[(\-?\d+),(\-?\d+)\]\[(\-?\d+),(\-?\d+)\]")


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


# ---------- misc ----------

def _utc_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


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
        return (
            f"[{self.idx}] {self.class_name or '-'} | "
            f"id={self.resource_id or '-'} | "
            f"text={self.text or '-'} | "
            f"desc={self.content_desc or '-'} | "
            f"click={self.clickable} focusable={self.focusable} enabled={self.enabled} focused={self.focused} "
            f"center=({cx},{cy})"
        )


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

    dominant_pkg = Counter(packages).most_common(1)[0][0] if packages else ""
    return candidates, size, dominant_pkg


# ---------- instruction parsing ----------

def _clean_place(s: str) -> str:
    s = (s or "").strip()
    # If the model captured a whole sentence, keep the tail after keywords.
    keywords = ["itinéraire", "itinerary", "trajet", "journey", "route", "between", "entre", "from", "de"]
    low = s.lower()
    cut = -1
    for kw in keywords:
        i = low.rfind(kw)
        if i >= 0:
            cut = max(cut, i + len(kw))
    if cut > 0 and cut < len(s):
        s = s[cut:].strip(" :,-\t\n")
    # If still too long, keep last 3 words (good compromise for "Luxembourg Gare")
    parts = s.split()
    if len(parts) > 4:
        s = " ".join(parts[-3:])
    return s.strip(" -\t\n")


def parse_targets_from_instruction(instruction: str) -> Dict[str, str]:
    """
    Robust-ish parsing for:
    - "Luxembourg -> Arlon"
    - "de Luxembourg à Arlon"
    - "entre Luxembourg et Arlon"
    - "from Luxembourg to Arlon"
    """
    s = instruction or ""

    patterns = [
        r"(.+?)\s*(?:->|→)\s*(.+)$",
        r"(?:de|from)\s+(.+?)\s*(?:à|to)\s*(.+)$",
        r"(?:entre|between)\s+(.+?)\s*(?:et|and)\s*(.+)$",
    ]

    for pat in patterns:
        m = re.search(pat, s, flags=re.IGNORECASE)
        if m:
            start = _clean_place(m.group(1))
            dest = _clean_place(m.group(2))
            return {"start": start, "destination": dest}

    return {"start": "", "destination": ""}


def parse_constraints_from_instruction(instruction: str) -> Dict:
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
        "exclude_modes": exclude,
        "allowed_services": [x.upper() for x in allowed_services],
        "rail_only": ("bus" in exclude or "tram" in exclude),
        "time_hint": "now" if ("now" in s or "maintenant" in s) else "",
    }


# ---------- candidate scoring / filtering ----------

def is_ime_candidate(c: Candidate) -> bool:
    pkg = _norm(c.package)
    if "inputmethod" in pkg or "keyboard" in pkg:
        return True
    txt = (c.text or "").strip()
    if txt in {"ESC", "ALT", "CTRL", "HOME", "END", "PGUP", "PGDN", "↹", "⇳", "☰", "↑", "↓", "←", "→"}:
        return True
    return False


def is_actionable_tap(c: Candidate) -> bool:
    # In real Android dumps, some tappable things are "focusable" but not "clickable".
    return bool(c.enabled and c.center and (c.clickable or c.focusable) and not is_ime_candidate(c))


def score_candidate(c: Candidate, dominant_pkg: str) -> int:
    s = 0
    if is_actionable_tap(c):
        s += 120
    if c.package and dominant_pkg and c.package == dominant_pkg:
        s += 30
    if c.resource_id:
        s += 10
    if c.text or c.content_desc:
        s += 5
    if "EditText" in (c.class_name or ""):
        s += 15
    if c.focused:
        s += 10
    if is_ime_candidate(c):
        s -= 300
    return s


def surface_candidates(all_nodes: List[Candidate], dominant_pkg: str, limit: int) -> List[Candidate]:
    scored = [(score_candidate(c, dominant_pkg), c.idx, c) for c in all_nodes]
    scored.sort(key=lambda t: (t[0], -t[1]), reverse=True)
    return [c for _, _, c in scored[:limit]]


def compact_state(surfaced: List[Candidate], phase: str, targets: Dict[str, str], constraints: Dict, size: Dict[str, int],
                  max_candidates: int = 24, maxlen: int = 90) -> Dict:
    def clip(x: str) -> str:
        x = x or ""
        return x if len(x) <= maxlen else x[: maxlen - 1] + "…"

    out = []
    for c in surfaced:
        if not is_actionable_tap(c):
            continue
        out.append(
            {
                "idx": c.idx,
                "id": c.resource_id or "",
                "text": clip(c.text),
                "desc": clip(c.content_desc),
                "focused": bool(c.focused),
            }
        )

    return {
        "phase": phase,
        "targets": targets,
        "constraints": constraints,
        "size": size,
        "candidates": out[:max_candidates],
    }


def state_signature(compact: Dict) -> str:
    payload = json.dumps(compact, ensure_ascii=False, sort_keys=True)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:12]


# ---------- phase detection ----------

def detect_phase(all_nodes: List[Candidate]) -> str:
    # Time picker dialog (your runner log showed NumberPickers + OK/CANCEL)
    if any(c.resource_id == "android:id/numberpicker_input" for c in all_nodes) and any((c.text or "").upper() in {"OK", "CANCEL"} for c in all_nodes):
        return "dialog_time_picker"

    # Location picker (typing station)
    if any(c.resource_id.endswith(":id/input_location_name") for c in all_nodes):
        # try to infer which one
        fld = next((c for c in all_nodes if c.resource_id.endswith(":id/input_location_name")), None)
        t = _norm(fld.text if fld else "")
        if "start" in t:
            return "pick_start"
        if "destination" in t or "target" in t:
            return "pick_destination"
        return "pick_unknown"

    # Drawer open (menu list)
    drawer_labels = {"Home", "Trip Planner", "Departures", "My Trips", "Map", "Tickets", "Infos CFL", "Works", "Alarms", "Settings"}
    txts = {(c.text or "").strip() for c in all_nodes if (c.text or "").strip()}
    if len(drawer_labels.intersection(txts)) >= 3:
        return "drawer_open"

    # Trip form on Home (resource ids exist) OR Trip Planner screen (content-desc exists)
    if any(c.resource_id.endswith(":id/input_start") for c in all_nodes) or any((c.content_desc or "") == "Select start" for c in all_nodes):
        # heuristic: dedicated Trip Planner has SEARCH button text
        if any((c.text or "").strip().upper() == "SEARCH" for c in all_nodes) or any(c.resource_id.endswith(":id/button_search_default") for c in all_nodes):
            return "tripplanner_form"
        return "home_form"

    return "unknown"


# ---------- history ----------

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
        act = it.get("action", {})
        lines.append(
            f"- ts={it.get('ts','?')} phase={it.get('phase','?')} sig={it.get('state_sig','?')} "
            f"action={act.get('action','?')} tidx={act.get('target_idx',None)} key={act.get('keycode',None)} "
            f"text={(act.get('text','') or '')[:24]} reason={(act.get('reason','') or '')[:60]}"
        )
    return "\n".join(lines)


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
        and (last_act.get("text") or "") == (action.get("text") or "")
    )


# ---------- rule-based helpers ----------

def _bounds_contains(outer: Tuple[int, int, int, int], inner: Tuple[int, int, int, int]) -> bool:
    ox1, oy1, ox2, oy2 = outer
    ix1, iy1, ix2, iy2 = inner
    return ox1 <= ix1 and oy1 <= iy1 and ox2 >= ix2 and oy2 >= iy2


def _clickable_container_for_text(all_nodes: List[Candidate], label: str) -> Optional[Candidate]:
    """
    Drawer items: the text node often isn't clickable; a parent container is.
    We approximate by finding the smallest clickable/focusable node whose bounds contain the text bounds.
    """
    label = (label or "").strip()
    if not label:
        return None

    text_nodes = [c for c in all_nodes if (c.text or "").strip() == label and parse_bounds(c.bounds)]
    if not text_nodes:
        return None
    tn = text_nodes[0]
    tb = parse_bounds(tn.bounds)
    if not tb:
        return None

    containers: List[Tuple[int, Candidate]] = []
    for c in all_nodes:
        if not is_actionable_tap(c):
            continue
        cb = parse_bounds(c.bounds)
        if not cb:
            continue
        if _bounds_contains(cb, tb):
            area = (cb[2] - cb[0]) * (cb[3] - cb[1])
            containers.append((area, c))

    if not containers:
        return None
    containers.sort(key=lambda t: t[0])  # smallest container wins
    return containers[0][1]


def _contains_city(c: Candidate, city: str) -> bool:
    if not city:
        return False
    city_l = _norm(city)
    return city_l in _norm(c.text) or city_l in _norm(c.content_desc)


def rule_based_action(all_nodes: List[Candidate], phase: str, targets: Dict[str, str], constraints: Dict) -> Optional[Dict]:
    start = (targets.get("start") or "").strip()
    dest = (targets.get("destination") or "").strip()
    time_hint = (constraints.get("time_hint") or "").strip()

    # 0) Dialogs: avoid getting stuck in time picker if user asked "now"/"maintenant"
    if phase == "dialog_time_picker":
        # Prefer CANCEL if visible; else BACK
        cancel = next((c for c in all_nodes if (c.text or "").upper() == "CANCEL" and is_actionable_tap(c)), None)
        okb = next((c for c in all_nodes if (c.text or "").upper() == "OK" and is_actionable_tap(c)), None)
        if time_hint == "now" and cancel:
            return {"action": "tap", "target_idx": cancel.idx, "reason": "Close time picker (keep 'now')"}
        if cancel:
            return {"action": "tap", "target_idx": cancel.idx, "reason": "Close time picker (CANCEL)"}
        if okb and time_hint != "now":
            return {"action": "tap", "target_idx": okb.idx, "reason": "Confirm time picker (OK)"}
        return {"action": "key", "keycode": 4, "reason": "Close dialog (BACK)"}

    # 1) Drawer open: go to Trip Planner
    if phase == "drawer_open":
        item = _clickable_container_for_text(all_nodes, "Trip Planner")
        if item:
            return {"action": "tap", "target_idx": item.idx, "reason": "Open Trip Planner from drawer"}
        # fallback: BACK
        return {"action": "key", "keycode": 4, "reason": "Close drawer (BACK)"}

    # 2) Unknown: try open drawer
    if phase == "unknown":
        burger = next((c for c in all_nodes if (c.content_desc or "") == "Show navigation drawer" and is_actionable_tap(c)), None)
        if burger:
            return {"action": "tap", "target_idx": burger.idx, "reason": "Open navigation drawer"}
        # If already on a form but detection failed, do nothing destructive
        return {"action": "done", "reason": "Unknown screen and no safe navigation target", "target_idx": None, "text": "", "keycode": None}

    # 3) Trip forms (Home or TripPlanner): set start, set destination, search
    if phase in {"home_form", "tripplanner_form"}:
        start_field = None
        dest_field = None
        search_btn = None

        # Home screen uses resource-ids
        if phase == "home_form":
            start_field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_start") and is_actionable_tap(c)), None)
            dest_field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_target") and is_actionable_tap(c)), None)
            search_btn = next((c for c in all_nodes if c.resource_id.endswith(":id/button_search") and is_actionable_tap(c)), None)

        # TripPlanner screen uses content-desc + SEARCH
        if phase == "tripplanner_form":
            start_field = next((c for c in all_nodes if (c.content_desc or "") == "Select start" and is_actionable_tap(c)), None)
            dest_field = next((c for c in all_nodes if (c.content_desc or "") == "Select destination" and is_actionable_tap(c)), None)
            search_btn = next((c for c in all_nodes if (c.text or "").strip().upper() == "SEARCH" and is_actionable_tap(c)), None)

        # Heuristic: if placeholders are still there, tap them
        if start_field and start:
            return {"action": "tap", "target_idx": start_field.idx, "reason": f"Set start to '{start}'"}
        if dest_field and dest:
            return {"action": "tap", "target_idx": dest_field.idx, "reason": f"Set destination to '{dest}'"}
        if search_btn:
            return {"action": "tap", "target_idx": search_btn.idx, "reason": "Launch search"}

        return None

    # 4) Picker: type and pick
    if phase in {"pick_start", "pick_destination", "pick_unknown"}:
        want = start if phase == "pick_start" else dest if phase == "pick_destination" else (start or dest)

        field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_location_name")), None)
        if field and want:
            if field.focused:
                return {"action": "type", "text": want, "reason": f"Type '{want}' in location field"}
            # field might not be clickable but is usually focusable; allow tap by idx anyway if actionable
            if is_actionable_tap(field):
                return {"action": "tap", "target_idx": field.idx, "reason": "Focus location input"}
            # fallback: BACK (avoid IME)
            return {"action": "key", "keycode": 4, "reason": "Field not tappable; try BACK"}

        # If a matching list entry is visible, pick it
        list_entries = [c for c in all_nodes if is_actionable_tap(c)]
        matching = [c for c in list_entries if _contains_city(c, want)]
        if want and matching:
            matching.sort(key=lambda c: (len((c.content_desc or "").strip()), c.idx), reverse=True)
            best = matching[0]
            return {"action": "tap", "target_idx": best.idx, "reason": f"Select '{want}' from suggestions"}

        # close keyboard overlay
        if any(is_ime_candidate(c) for c in all_nodes):
            return {"action": "key", "keycode": 4, "reason": "Close keyboard overlay (BACK)"}

        return None

    return None


# ---------- LLM prompt + call ----------

def build_prompt(instruction: str, compact: Dict, history_text: str, state_sig: str) -> str:
    return textwrap.dedent(
        f"""
        You control an Android app via adb + uiautomator.
        You are NOT a chatbot. You are a deterministic next-action planner.

        OBJECTIVE:
        {instruction}

        HARD RULES:
        - Output ONE JSON object only.
        - One action only: tap OR type OR key OR done.
        - For tap: you MUST choose a target_idx that exists in UI_STATE.candidates[].idx (no invented coordinates).
        - Never tap keyboard keys (ESC/ALT/etc).
        - If the UI state signature is unchanged vs last step, do NOT repeat the same action on the same target_idx.

        UI STATE SIGNATURE (this step): {state_sig}

        RECENT HISTORY:
        {history_text}

        UI_STATE (compact JSON):
        {json.dumps(compact, ensure_ascii=False)}

        Output schema:
        {{
          "action": "tap|type|key|done",
          "target_idx": number|null,
          "text": string,
          "keycode": number|null,
          "reason": string
        }}
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
    max_tokens = int(os.getenv("LLM_MAX_TOKENS", "200"))
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
                    "For tap: use target_idx from UI_STATE.candidates.\n"
                    'Schema: {"action":"tap|type|key|done","target_idx":number|null,"text":string,"keycode":number|null,"reason":string}\n'
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


# ---------- action validation ----------

def validate_action(action: Dict, size: Dict[str, int], all_nodes_by_idx: Dict[int, Candidate], allowed_tap_idxs: set) -> Dict:
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
        if tidx not in allowed_tap_idxs:
            raise ValueError(f"target_idx={tidx} is not in the allowed compact candidate list")

        c = all_nodes_by_idx.get(tidx)
        if c is None:
            raise ValueError(f"target_idx={tidx} not found")
        if not is_actionable_tap(c):
            raise ValueError(f"target_idx={tidx} not tappable (clickable/focusable+enabled+center required)")
        if c.center is None:
            raise ValueError(f"target_idx={tidx} missing center")

        x, y = c.center
        max_x = max(1, int(size.get("width", 1080)))
        max_y = max(1, int(size.get("height", 2400)))
        if x <= 0 or y <= 0 or x > max_x or y > max_y:
            raise ValueError("Tap coords outside screen bounds")

        safe["target_idx"] = tidx
        safe["x"], safe["y"] = x, y

    elif act == "type":
        txt = action.get("text")
        if txt is None:
            raise ValueError("Type action missing text")
        safe["text"] = str(txt)

    elif act == "key":
        kc = action.get("keycode", None)
        if kc is None:
            raise ValueError("Key action missing keycode")
        safe["keycode"] = int(kc)

    return safe


# ---------- main ----------

def main() -> int:
    parser = argparse.ArgumentParser(description="LLM-guided Android explorer (Trip Planner disciplined)")
    parser.add_argument("--instruction", required=True, help="Goal for the agent")
    parser.add_argument("--xml", required=True, help="Path to uiautomator dump XML")
    parser.add_argument("--model", default=os.environ.get("LLM_MODEL", "local-model"))
    parser.add_argument("--limit", type=int, default=120, help="Max surfaced candidates")
    parser.add_argument("--no_llm", action="store_true", help="Only rule-based decisions")
    parser.add_argument("--history_file", default=os.environ.get("LLM_HISTORY_FILE", ""), help="Path to history JSONL")
    parser.add_argument("--history_limit", type=int, default=int(os.environ.get("LLM_HISTORY_LIMIT", "10")))
    args = parser.parse_args()

    all_nodes, size, dominant_pkg = extract_candidates(args.xml)
    all_nodes_by_idx = {c.idx: c for c in all_nodes}

    targets = parse_targets_from_instruction(args.instruction)
    constraints = parse_constraints_from_instruction(args.instruction)
    phase = detect_phase(all_nodes)

    surfaced = surface_candidates(all_nodes, dominant_pkg, limit=args.limit)
    compact = compact_state(surfaced, phase, targets, constraints, size)

    sig = state_signature(compact)
    hist = load_history(args.history_file, limit=args.history_limit)
    hist_text = history_for_prompt(hist)
    allowed_tap_idxs = {c["idx"] for c in compact.get("candidates", [])}

    log(f"phase={phase} state_sig={sig}")
    log("Compact UI sent to LLM:")
    log(json.dumps(compact, ensure_ascii=False, indent=2))

    # 1) rule-based fast path
    rb = rule_based_action(all_nodes, phase, targets, constraints)
    if rb:
        try:
            action = validate_action(rb, size, all_nodes_by_idx, allowed_tap_idxs) if rb.get("action") == "tap" else {
                "action": rb.get("action"),
                "target_idx": rb.get("target_idx", None),
                "x": None, "y": None,
                "text": rb.get("text", "") or "",
                "keycode": rb.get("keycode", None),
                "reason": rb.get("reason", "") or "",
            }
            # If tap, fill x/y
            if action["action"] == "tap":
                c = all_nodes_by_idx[action["target_idx"]]
                action["x"], action["y"] = c.center
        except Exception as e:
            warn(f"Rule-based action invalid: {e}")
            action = {"action": "done", "reason": f"Rule-based invalid: {e}", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}

        if is_repeat_loop(hist, sig, action):
            warn("Repeat-loop detected on identical state_sig; forcing BACK.")
            action = {"action": "key", "target_idx": None, "x": None, "y": None, "text": "", "keycode": 4, "reason": "Loop breaker: BACK"}

        append_history(
            args.history_file,
            {
                "ts": _utc_iso(),
                "phase": phase,
                "state_sig": sig,
                "instruction": args.instruction[:220],
                "action": {
                    "action": action.get("action"),
                    "target_idx": action.get("target_idx"),
                    "keycode": action.get("keycode"),
                    "text": action.get("text", ""),
                    "reason": action.get("reason", ""),
                },
            },
        )

        print(json.dumps(action, ensure_ascii=False))
        return 0

    if args.no_llm:
        action = {"action": "done", "reason": "No rule-based decision and --no_llm set", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}
        print(json.dumps(action, ensure_ascii=False))
        return 0

    # 2) LLM fallback
    prompt = build_prompt(args.instruction, compact, hist_text, sig)

    try:
        raw_action = call_llm(prompt, args.model)
    except Exception as e:
        action = safe_action_from_error(e)
        print(json.dumps(action, ensure_ascii=False))
        return 0

    log(f"Raw LLM response: {raw_action}")

    try:
        action = validate_action(raw_action, size, all_nodes_by_idx, allowed_tap_idxs)
    except Exception as e:
        warn(f"Action validation failed: {e}")
        action = {"action": "done", "reason": f"Invalid action from LLM: {e}", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}

    if is_repeat_loop(hist, sig, action):
        warn("Repeat-loop detected on identical state_sig; forcing BACK.")
        action = {"action": "key", "target_idx": None, "x": None, "y": None, "text": "", "keycode": 4, "reason": "Loop breaker: BACK"}

    append_history(
        args.history_file,
        {
            "ts": _utc_iso(),
            "phase": phase,
            "state_sig": sig,
            "instruction": args.instruction[:220],
            "action": {
                "action": action.get("action"),
                "target_idx": action.get("target_idx"),
                "keycode": action.get("keycode"),
                "text": action.get("text", ""),
                "reason": action.get("reason", ""),
            },
        },
    )

    print(json.dumps(action, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
