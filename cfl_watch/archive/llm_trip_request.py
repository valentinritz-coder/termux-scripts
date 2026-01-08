#!/usr/bin/env python3
"""
Parse a human instruction into a strict TripRequest JSON (LLM as parser, not clicker).

Output JSON schema:
{
  "start": "LUXEMBOURG",
  "destination": "ARLON",
  "when": "now" | "YYYY-MM-DDTHH:MM",
  "arrive_by": false,
  "via": [],
  "rail_only": true,
  "exclude_modes": ["bus","tram"],
  "allowed_services": ["TGV","IC","TER","RE","RB"]
}
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys
from datetime import datetime
from typing import Any, Dict, List

import requests


def _norm_base(url: str) -> str:
    url = (url or "").rstrip("/")
    if url.endswith("/v1"):
        url = url[:-3]
    return url


def _chat_completions_url() -> str:
    base = _norm_base(os.getenv("OPENAI_BASE_URL", "http://127.0.0.1:8001"))
    return f"{base}/v1/chat/completions"


def _fallback_parse(instruction: str) -> Dict[str, Any]:
    s = instruction or ""
    m = re.search(r"([A-Za-zÀ-ÿ0-9' -]{2,})\s*(?:->|→)\s*([A-Za-zÀ-ÿ0-9' -]{2,})", s, flags=re.IGNORECASE)
    if not m:
        m = re.search(r"entre\s+(.+?)\s+et\s+(.+?)(?:\s|$)", s, flags=re.IGNORECASE)
    start = (m.group(1).strip() if m else "").upper()
    dest = (m.group(2).strip() if m else "").upper()

    lower = s.lower()
    rail_only = ("train" in lower) or ("rail" in lower) or ("pas de bus" in lower) or ("sans bus" in lower)
    exclude = []
    if "bus" in lower:
        exclude.append("bus")
    if "tram" in lower:
        exclude.append("tram")

    return {
        "start": start,
        "destination": dest,
        "when": "now",
        "arrive_by": False,
        "via": [],
        "rail_only": bool(rail_only),
        "exclude_modes": exclude,
        "allowed_services": ["TGV", "IC", "TER", "RE", "RB"],
    }


def _parse_llm_response(content: str) -> Dict[str, Any]:
    if content is None:
        raise ValueError("Empty LLM content")
    s = content.strip()
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s, flags=re.IGNORECASE | re.DOTALL).strip()
    m = re.search(r"\{.*\}", s, flags=re.DOTALL)
    if m:
        s = m.group(0).strip()

    try:
        obj = json.loads(s)
    except Exception:
        obj = ast.literal_eval(s)

    if not isinstance(obj, dict):
        raise ValueError("LLM did not return a JSON object")
    return obj


def _call_llm(instruction: str, model: str) -> Dict[str, Any]:
    url = _chat_completions_url()
    api_key = os.getenv("OPENAI_API_KEY", "dummy")

    timeout = float(os.getenv("OPENAI_TIMEOUT", "60"))
    max_tokens = int(os.getenv("LLM_MAX_TOKENS", "256"))
    temperature = float(os.getenv("LLM_TEMPERATURE", "0"))

    system = (
        "You are a strict trip-request parser.\n"
        "Return ONLY a single JSON object (no markdown).\n"
        "Do not include extra keys.\n"
        "All station names must be uppercase.\n"
        "Schema:\n"
        "{"
        '"start":string,'
        '"destination":string,'
        '"when":"now"|"YYYY-MM-DDTHH:MM",'
        '"arrive_by":boolean,'
        '"via":array[string],'
        '"rail_only":boolean,'
        '"exclude_modes":array[string],'
        '"allowed_services":array[string]'
        "}\n"
        "Defaults: when='now', arrive_by=false, via=[], rail_only=true if user says train-only, "
        "exclude_modes includes bus/tram if user excludes them, allowed_services defaults to [TGV,IC,TER,RE,RB].\n"
    )

    user = (
        "Instruction:\n"
        f"{instruction}\n\n"
        "Interpret relative time words:\n"
        "- 'maintenant/now' => when='now'\n"
        "- If user gives a time/date and you can parse it safely, output when='YYYY-MM-DDTHH:MM'. "
        "If unsure, keep when='now'.\n"
    )

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
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
        raise RuntimeError(f"LLM HTTP {r.status_code}: {r.text[:500]}")

    data = r.json()
    content = data["choices"][0]["message"].get("content") or ""
    return _parse_llm_response(content)


def _validate(req: Dict[str, Any]) -> Dict[str, Any]:
    out = {
        "start": str(req.get("start", "")).strip().upper(),
        "destination": str(req.get("destination", "")).strip().upper(),
        "when": str(req.get("when", "now")).strip(),
        "arrive_by": bool(req.get("arrive_by", False)),
        "via": req.get("via") if isinstance(req.get("via"), list) else [],
        "rail_only": bool(req.get("rail_only", True)),
        "exclude_modes": req.get("exclude_modes") if isinstance(req.get("exclude_modes"), list) else [],
        "allowed_services": req.get("allowed_services") if isinstance(req.get("allowed_services"), list) else ["TGV", "IC", "TER", "RE", "RB"],
    }

    if not out["start"] or not out["destination"]:
        raise ValueError("Missing start/destination")

    if out["when"] != "now":
        # light sanity: accept YYYY-MM-DDTHH:MM
        if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$", out["when"]):
            out["when"] = "now"

    # normalize modes/services
    out["exclude_modes"] = [str(x).lower() for x in out["exclude_modes"]]
    out["allowed_services"] = [str(x).upper() for x in out["allowed_services"]]
    out["via"] = [str(x).strip().upper() for x in out["via"] if str(x).strip()]

    return out


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--instruction", required=True)
    p.add_argument("--model", default=os.environ.get("LLM_MODEL", "local-model"))
    p.add_argument("--no_llm", action="store_true")
    args = p.parse_args()

    if args.no_llm:
        req = _fallback_parse(args.instruction)
        print(json.dumps(_validate(req), ensure_ascii=False))
        return 0

    try:
        req = _call_llm(args.instruction, args.model)
        print(json.dumps(_validate(req), ensure_ascii=False))
        return 0
    except Exception:
        # fallback if LLM is down or hallucinating
        req = _fallback_parse(args.instruction)
        print(json.dumps(_validate(req), ensure_ascii=False))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
