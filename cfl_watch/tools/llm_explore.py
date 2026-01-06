#!/usr/bin/env python3
"""
LLM-driven Android UI explorer for CFL Trip Planner (disciplined).

Two layers:
1) Trip intent -> plan JSON (from instruction). (Optional LLM, default heuristic)
2) UI stepper -> exactly ONE action based on: plan + compact UI state + history.

Discipline rules:
- Tap uses target_idx from provided candidates (no hallucinated x/y).
- One action per run: tap OR type OR key OR done.
- Output strict JSON (and we validate / sanitize).
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


# ---------------- logging ----------------


def log(msg: str) -> None:
    print(f"[*] {msg}", file=sys.stderr)


def warn(msg: str) -> None:
    print(f"[!] {msg}", file=sys.stderr)


# ---------------- URL helpers ----------------


def _norm_base(url: str) -> str:
    url = (url or "").rstrip("/")
    if url.endswith("/v1"):
        url = url[:-3]
    return url


def _chat_completions_url() -> str:
    base = _norm_base(os.getenv("OPENAI_BASE_URL", "http://127.0.0.1:8001"))
    return f"{base}/v1/chat/completions"


# ---------------- helpers ----------------


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


# ---------------- history ----------------


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
            f"- ts={it.get('ts','?')} phase={it.get('phase','?')} sig={it.get('state_sig','?')}"
            f" act={act.get('action','?')} tidx={act.get('target_idx',None)} key={act.get('keycode',None)}"
            f" text={(act.get('text','') or '')[:20]} reason={(act.get('reason','') or '')[:70]}"
        )
    return "\n".join(lines)


def is_repeat_loop(hist: List[Dict], sig: str, action: Dict) -> bool:
    if not hist:
        return False
    last = hist[-1]
    if last.get("state_sig") != sig:
        return False
    la = last.get("action", {})
    return (
        la.get("action") == action.get("action")
        and la.get("target_idx") == action.get("target_idx")
        and la.get("keycode") == action.get("keycode")
        and (la.get("text", "") == action.get("text", ""))
    )


# ---------------- trip plan (intent) ----------------


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

    # “train only” intent
    train_only = bool(re.search(r"\btrain\s+uniquement\b|\bonly\s+train\b|\brail\s+only\b", s))

    exclude_modes = []
    for mode in ["bus", "tram", "metro", "subway", "coach"]:
        if re.search(rf"\bpas\s+de\s+{mode}\b|\bno\s+{mode}\b|\bwithout\s+{mode}\b|\bexclude\s+{mode}\b", s):
            exclude_modes.append(mode)

    allowed_services = sorted(set(re.findall(r"\b(TGV|IC|TER|RE|RB)\b", instruction, flags=re.IGNORECASE)))
    if not allowed_services:
        allowed_services = ["TGV", "IC", "TER", "RE", "RB"]

    when = "now"
    if re.search(r"\bmaintenant\b|\bnow\b|\bde\s+suite\b", s):
        when = "now"

    return {
        "when": when,  # only "now" supported for now (keeps UI simple)
        "no_via": no_via,
        "train_only": train_only or ("bus" in exclude_modes) or ("tram" in exclude_modes),
        "exclude_modes": exclude_modes,
        "allowed_services": [x.upper() for x in allowed_services],
    }


def build_trip_plan(instruction: str) -> Dict:
    t = parse_targets_from_instruction(instruction)
    c = parse_constraints_from_instruction(instruction)
    return {
        "start": t.get("start", ""),
        "destination": t.get("destination", ""),
        "when": c.get("when", "now"),
        "no_via": bool(c.get("no_via")),
        "train_only": bool(c.get("train_only")),
        "exclude_modes": c.get("exclude_modes", []),
        "allowed_services": c.get("allowed_services", []),
        "raw_instruction": (instruction or "")[:400],
    }


def call_llm_trip_plan(instruction: str, model: str) -> Dict:
    """
    Optional: let the LLM extract a plan from text.
    If it fails, caller should fallback to heuristic.
    """
    url = _chat_completions_url()
    api_key = os.getenv("OPENAI_API_KEY", "dummy")

    timeout = float(os.getenv("OPENAI_TIMEOUT", "60"))
    temperature = float(os.getenv("LLM_TEMPERATURE", "0"))
    max_tokens = int(os.getenv("LLM_PLAN_MAX_TOKENS", "256"))

    schema_hint = {
        "start": "Luxembourg",
        "destination": "Arlon",
        "when": "now",
        "no_via": True,
        "train_only": True,
        "exclude_modes": ["bus", "tram"],
        "allowed_services": ["TGV", "IC", "TER", "RE", "RB"],
    }

    prompt = textwrap.dedent(
        f"""
        Extract a Trip Planner plan from the instruction.
        Return ONLY JSON.

        Instruction:
        {instruction}

        JSON schema (example values):
        {json.dumps(schema_hint, ensure_ascii=False)}

        Rules:
        - when: "now" unless a specific date/time is clearly stated (then still return "now" if unsure).
        - train_only true if user says train only / excludes bus/tram.
        - allowed_services: include any of [TGV,IC,TER,RE,RB] mentioned; otherwise default to all of them.
        """
    ).strip()

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "Return ONLY one JSON object. No markdown."},
            {"role": "user", "content": prompt},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
        "response_format": {"type": "json_object"},
    }

    with requests.Session() as sess:
        r = sess.post(
            url,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
            json=payload,
            timeout=timeout,
        )
    if not r.ok:
        raise RuntimeError(f"LLM(plan) HTTP {r.status_code}: {r.text[:2000]}")
    data = r.json()
    content = data["choices"][0]["message"].get("content") or ""
    return parse_llm_response(content)


# ---------------- UI model ----------------


@dataclass(frozen=True)
class Candidate:
    idx: int
    package: str
    class_name: str
    resource_id: str
    text: str
    content_desc: str
    label: str  # derived label (can come from descendants)
    clickable: bool
    enabled: bool
    focusable: bool
    focused: bool
    bounds: str
    center: Optional[Tuple[int, int]]


def is_ime_candidate_pkg(pkg: str) -> bool:
    p = _norm(pkg)
    return ("inputmethod" in p) or ("keyboard" in p)


def is_ime_candidate_text(txt: str) -> bool:
    t = (txt or "").strip()
    return t in {"ESC", "ALT", "CTRL", "HOME", "END", "PGUP", "PGDN", "↹", "⇳", "☰", "↑", "↓", "←", "→"}


def is_ime_candidate(c: Candidate) -> bool:
    if is_ime_candidate_pkg(c.package):
        return True
    if is_ime_candidate_text(c.text) or is_ime_candidate_text(c.content_desc):
        return True
    return False


def _derive_label(node: ET.Element) -> str:
    """
    If node has no text/desc, try to borrow a label from descendants (menu items issue).
    Keep it short and human-ish.
    """
    a = node.attrib
    txt = (a.get("text", "") or "").strip()
    desc = (a.get("content-desc", "") or "").strip()
    if txt:
        return txt
    if desc:
        return desc

    # descend a bit: first meaningful text/desc
    for d in node.iter("node"):
        if d is node:
            continue
        da = d.attrib
        dt = (da.get("text", "") or "").strip()
        dd = (da.get("content-desc", "") or "").strip()
        if dt:
            return dt
        if dd:
            return dd

    rid = (a.get("resource-id", "") or "").strip()
    if rid:
        return rid.split("/")[-1]
    return ""


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

        txt = a.get("text", "") or ""
        desc = a.get("content-desc", "") or ""
        label = _derive_label(node)

        candidates.append(
            Candidate(
                idx=idx,
                package=pkg,
                class_name=a.get("class", ""),
                resource_id=a.get("resource-id", ""),
                text=txt,
                content_desc=desc,
                label=label,
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


# ---------------- phase detection ----------------


def detect_phase(all_nodes: List[Candidate]) -> str:
    ids = [c.resource_id for c in all_nodes if c.resource_id]
    texts = " ".join([c.text for c in all_nodes if c.text])
    descs = " ".join([c.content_desc for c in all_nodes if c.content_desc])

    # Drawer/menu open
    if any("drawer_list" in rid for rid in ids) or any("drawer_layout" in rid for rid in ids):
        return "drawer"

    # Location picker
    if any(rid.endswith(":id/input_location_name") for rid in ids):
        return "picker"

    # Trip planner form (Trip Planner screen)
    if any(rid.endswith(":id/button_search_default") or rid.endswith(":id/button_search") for rid in ids):
        return "tripplanner_form"

    # Home has input_start/input_target too in your dumps
    if any("id/input_start" in rid for rid in ids) and any("id/input_target" in rid for rid in ids):
        # If the big SEARCH button is visible, treat as tripplanner_form anyway
        if "SEARCH" in texts or "SEARCH" in descs:
            return "tripplanner_form"
        return "home"

    # Date picker-ish (your log showed day cells like "03 January 2026")
    if re.search(r"\b\d{2}\s+\w+\s+\d{4}\b", descs) and ("January" in descs or "janvier" in descs):
        return "datetime_picker"

    return "unknown"


# ---------------- state shaping ----------------


def score_candidate(c: Candidate, dominant_pkg: str) -> int:
    s = 0
    if c.clickable and c.enabled and c.center:
        s += 100
    if c.label:
        s += 15
    if c.resource_id:
        s += 8
    if c.package and dominant_pkg and c.package == dominant_pkg:
        s += 25
    if "EditText" in (c.class_name or ""):
        s += 20
    if c.focused:
        s += 10
    if is_ime_candidate(c):
        s -= 250
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


def compact_state(surfaced: List[Candidate], phase: str, plan: Dict, size: Dict[str, int], max_candidates: int = 24) -> Dict:
    def clip(s: str, n: int = 90) -> str:
        s = (s or "").strip()
        return s if len(s) <= n else s[: n - 1] + "…"

    candidates = []
    for c in surfaced:
        if not (c.clickable and c.enabled and c.center):
            continue
        if is_ime_candidate(c):
            continue
        candidates.append(
            {
                "idx": c.idx,
                "id": c.resource_id,
                "label": clip(c.label),
                "text": clip(c.text),
                "desc": clip(c.content_desc),
                "focused": bool(c.focused),
                "center": c.center,  # debug only (LLM must not invent coords)
            }
        )

    return {
        "phase": phase,
        "plan": plan,
        "size": size,
        "candidates": candidates[:max_candidates],
    }


def state_signature(compact: Dict) -> str:
    c = json.loads(json.dumps(compact))  # deep copy
    for cand in c.get("candidates", []):
        cand.pop("center", None)  # stabilize signature
    payload = json.dumps(c, ensure_ascii=False, sort_keys=True)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:12]


# ---------------- rule-based fast path ----------------


def _find_by_label(all_nodes: List[Candidate], needle: str) -> Optional[Candidate]:
    n = _norm(needle)
    best = None
    best_score = -1
    for c in all_nodes:
        if not (c.clickable and c.enabled and c.center):
            continue
        blob = f"{_norm(c.label)} {_norm(c.text)} {_norm(c.content_desc)} {_norm(c.resource_id)}"
        if n in blob:
            score = len(c.label or "") + len(c.text or "") + len(c.content_desc or "")
            if score > best_score:
                best_score = score
                best = c
    return best


def _find_start_field(all_nodes: List[Candidate]) -> Optional[Candidate]:
    # Prefer resource-id if available, else content-desc
    for c in all_nodes:
        if c.resource_id.endswith(":id/input_start") and c.center and c.enabled:
            return c
    return _find_by_label(all_nodes, "select start")


def _find_dest_field(all_nodes: List[Candidate]) -> Optional[Candidate]:
    for c in all_nodes:
        if c.resource_id.endswith(":id/input_target") and c.center and c.enabled:
            return c
    return _find_by_label(all_nodes, "select destination")


def _find_search_button(all_nodes: List[Candidate]) -> Optional[Candidate]:
    for c in all_nodes:
        if c.resource_id.endswith(":id/button_search_default") and c.center and c.enabled:
            return c
    for c in all_nodes:
        if c.resource_id.endswith(":id/button_search") and c.center and c.enabled:
            return c
    # fallback by visible label
    return _find_by_label(all_nodes, "search")


def _contains_city(c: Candidate, city: str) -> bool:
    if not city:
        return False
    cl = _norm(city)
    blob = f"{_norm(c.label)} {_norm(c.text)} {_norm(c.content_desc)}"
    return cl in blob


def rule_based_action(all_nodes: List[Candidate], phase: str, plan: Dict) -> Optional[Dict]:
    start = (plan.get("start") or "").strip()
    dest = (plan.get("destination") or "").strip()

    # If date picker popped and plan is "now": escape it.
    if phase == "datetime_picker" and (plan.get("when") == "now"):
        return {"action": "key", "keycode": 4, "reason": "Close date/time picker (BACK), plan is depart now"}

    # If drawer open, pick Trip Planner
    if phase == "drawer":
        tp = _find_by_label(all_nodes, "trip planner")
        if tp:
            return {"action": "tap", "target_idx": tp.idx, "reason": "Open Trip Planner from drawer menu"}
        return {"action": "key", "keycode": 4, "reason": "Close drawer (BACK) - Trip Planner not found"}

    # On home/unknown, prefer opening drawer then Trip Planner if visible
    if phase in {"home", "unknown"}:
        # Burger icon often has content-desc like "Open navigation drawer"
        burger = _find_by_label(all_nodes, "drawer") or _find_by_label(all_nodes, "navigation") or _find_by_label(all_nodes, "open")
        if burger:
            return {"action": "tap", "target_idx": burger.idx, "reason": "Open navigation drawer"}
        # Or just use start field on Home card if present
        sf = _find_start_field(all_nodes)
        if sf and start:
            return {"action": "tap", "target_idx": sf.idx, "reason": f"Open start field to set '{start}'"}
        return None

    # Trip Planner form: set start -> set dest -> search
    if phase == "tripplanner_form":
        sf = _find_start_field(all_nodes)
        df = _find_dest_field(all_nodes)
        sb = _find_search_button(all_nodes)

        def looks_placeholder(c: Optional[Candidate], placeholder: str) -> bool:
            if not c:
                return True
            blob = f"{_norm(c.text)} {_norm(c.content_desc)} {_norm(c.label)}"
            return placeholder in blob

        if sf and start and looks_placeholder(sf, "select start"):
            return {"action": "tap", "target_idx": sf.idx, "reason": f"Set start='{start}'"}
        if df and dest and looks_placeholder(df, "select destination"):
            return {"action": "tap", "target_idx": df.idx, "reason": f"Set destination='{dest}'"}
        if sb:
            return {"action": "tap", "target_idx": sb.idx, "reason": "Launch search"}
        return None

    # Picker: select visible match, else type, else back
    if phase == "picker":
        want = start or dest

        # If we can infer whether we're selecting start/destination from header label, do it:
        header = _find_by_label(all_nodes, "select start") or _find_by_label(all_nodes, "select destination")
        header_blob = ""
        if header:
            header_blob = f"{_norm(header.text)} {_norm(header.content_desc)} {_norm(header.label)}"
        if "start" in header_blob:
            want = start
        elif "destination" in header_blob:
            want = dest

        # Select visible list entry
        tappables = [c for c in all_nodes if c.clickable and c.enabled and c.center and not is_ime_candidate(c)]
        matching = [c for c in tappables if want and _contains_city(c, want)]
        if matching:
            matching.sort(key=lambda c: (len(c.label or c.content_desc or c.text), c.idx), reverse=True)
            best = matching[0]
            return {"action": "tap", "target_idx": best.idx, "reason": f"Select '{want}' from list"}

        # Focus field and type
        field = next((c for c in all_nodes if c.resource_id.endswith(":id/input_location_name") and c.center), None)
        if field and want:
            if field.focused:
                return {"action": "type", "text": want, "reason": f"Type '{want}' in location field"}
            return {"action": "tap", "target_idx": field.idx, "reason": "Focus location input"}

        # If keyboard overlay exists, close it
        if any(is_ime_candidate(c) for c in all_nodes):
            return {"action": "key", "keycode": 4, "reason": "Close keyboard overlay (BACK)"}

        return None

    return None


# ---------------- LLM prompt + call ----------------


def build_prompt(compact: Dict, history_text: str, state_sig: str) -> str:
    return textwrap.dedent(
        f"""
        You control an Android app via adb + uiautomator.
        You are NOT creative. You must be safe and deterministic.

        State signature (this turn): {state_sig}

        LOOP RULE:
        - If the last step has the SAME signature, do NOT repeat the exact same action on the same target_idx.
        - If stuck, prefer BACK (keycode 4) rather than random tapping.

        OUTPUT: return ONLY one JSON object with:
        {{
          "action": "tap" | "type" | "key" | "done",
          "target_idx": number | null,
          "text": string,
          "keycode": number | null,
          "reason": string
        }}

        Recent history:
        {history_text}

        UI state (compact JSON; tap targets are in candidates[].idx):
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


def _sanitize_action_obj(obj: Dict) -> Dict:
    """
    Defensive: some models literally copy placeholders like "tap|type|key|done".
    We'll infer a sane action if possible.
    """
    act = str(obj.get("action", "")).strip().lower()
    if act in {"tap", "type", "key", "done"}:
        return obj

    # Infer based on provided fields
    if obj.get("target_idx") is not None:
        obj["action"] = "tap"
        return obj
    if obj.get("text"):
        obj["action"] = "type"
        return obj
    if obj.get("keycode") is not None:
        obj["action"] = "key"
        return obj

    obj["action"] = "done"
    if not obj.get("reason"):
        obj["reason"] = f"Sanitized invalid action value: {act}"
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
                    "Action must be one of: tap, type, key, done.\n"
                    "For tap, you MUST pick a target_idx from candidates[].idx.\n"
                    "Never tap keyboard keys.\n"
                ),
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
        "response_format": {"type": "json_object"},
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

    content = data["choices"][0]["message"].get("content") or ""
    obj = parse_llm_response(content)
    return _sanitize_action_obj(obj)


def safe_action_from_error(err: Exception) -> Dict:
    return {"action": "done", "reason": f"LLM error: {err}", "target_idx": None, "text": "", "keycode": None}


def _index_by_idx(nodes: List[Candidate]) -> Dict[int, Candidate]:
    return {c.idx: c for c in nodes}


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
        if action.get("target_idx") is None:
            raise ValueError("Tap requires target_idx")
        tidx = int(action["target_idx"])
        c = surfaced_by_idx.get(tidx)
        if c is None:
            raise ValueError(f"target_idx={tidx} not in surfaced candidates")
        if not (c.clickable and c.enabled and c.center):
            raise ValueError(f"target_idx={tidx} not clickable+enabled+center")
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
            raise ValueError("Type missing text")
        safe["text"] = str(txt)

    elif act == "key":
        if action.get("keycode") is None:
            raise ValueError("Key missing keycode")
        safe["keycode"] = int(action.get("keycode"))

    return safe


# ---------------- main ----------------


def main() -> int:
    parser = argparse.ArgumentParser(description="CFL Trip Planner LLM explorer (disciplined)")
    parser.add_argument("--instruction", required=True, help="Goal in natural language")
    parser.add_argument("--xml", default="", help="Path to uiautomator dump XML (required unless --emit_plan)")
    parser.add_argument("--model", default=os.environ.get("LLM_MODEL", "local-model"))
    parser.add_argument("--limit", type=int, default=90, help="How many nodes to surface before compacting")
    parser.add_argument("--history_file", default=os.environ.get("LLM_HISTORY_FILE", ""), help="History JSONL path")
    parser.add_argument("--history_limit", type=int, default=int(os.environ.get("LLM_HISTORY_LIMIT", "10")))
    parser.add_argument("--no_llm", action="store_true", help="Disable LLM fallback (rule-based only)")
    parser.add_argument("--emit_plan", action="store_true", help="Output only the extracted trip plan JSON and exit")
    parser.add_argument("--plan_llm", action="store_true", help="Use LLM to extract plan (fallback to heuristic)")
    args = parser.parse_args()

    # Build trip plan first
    plan = build_trip_plan(args.instruction)
    if args.plan_llm and not args.emit_plan:
        # (for stepper we still prefer deterministic; plan_llm is mainly for emit_plan usage)
        pass

    if args.emit_plan:
        if args.plan_llm:
            try:
                plan = call_llm_trip_plan(args.instruction, args.model)
            except Exception as e:
                warn(f"Plan LLM failed, fallback to heuristic: {e}")
        print(json.dumps(plan, ensure_ascii=False))
        return 0

    if not args.xml:
        raise SystemExit("Missing --xml (uiautomator dump). Use --emit_plan if you only want the plan.")

    hist = load_history(args.history_file, limit=args.history_limit)
    hist_text = history_for_prompt(hist)

    all_nodes, size, dominant_pkg = extract_candidates(args.xml)
    phase = detect_phase(all_nodes)

    surfaced = surface_candidates(all_nodes, dominant_pkg, limit=args.limit)
    compact = compact_state(surfaced, phase, plan, size)
    sig = state_signature(compact)

    surfaced_by_idx = _index_by_idx(surfaced)

    log(f"phase={phase} state_sig={sig}")
    log("Compact state (what the LLM sees):")
    log(json.dumps(compact, ensure_ascii=False, indent=2))

    # Rule-based first (fast, reliable)
    rb = rule_based_action(all_nodes, phase, plan)
    if rb:
        raw = rb
    else:
        if args.no_llm:
            raw = {"action": "done", "reason": "No rule-based decision and --no_llm is set", "target_idx": None, "text": "", "keycode": None}
        else:
            prompt = build_prompt(compact, hist_text, sig)
            try:
                raw = call_llm(prompt, args.model)
            except Exception as e:
                raw = safe_action_from_error(e)

    log(f"Raw decision: {raw}")

    # Validate + compute x/y for tap
    try:
        action = validate_action(raw, size, surfaced_by_idx)
    except Exception as e:
        warn(f"Validation failed: {e}")
        action = {"action": "done", "reason": f"Invalid action: {e}", "target_idx": None, "x": None, "y": None, "text": "", "keycode": None}

    # Loop breaker (identical state + identical action)
    if is_repeat_loop(hist, sig, action):
        warn("Repeat-loop detected on identical state_sig -> forcing BACK.")
        action = {"action": "key", "target_idx": None, "x": None, "y": None, "text": "", "keycode": 4, "reason": "Loop breaker: BACK"}

    # Attach debug fields
    action_out = dict(action)
    action_out["state_sig"] = sig
    action_out["phase"] = phase

    # Persist history (after final action chosen)
    append_history(
        args.history_file,
        {
            "ts": _utc_iso(),
            "phase": phase,
            "state_sig": sig,
            "plan": plan,
            "action": {
                "action": action_out.get("action"),
                "target_idx": action_out.get("target_idx"),
                "keycode": action_out.get("keycode"),
                "text": action_out.get("text", ""),
                "reason": action_out.get("reason", ""),
            },
        },
    )

    print(json.dumps(action_out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
