#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Baseline reasoning: build prompt -> call LLM -> parse policy
"""

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from policy_orchestration import build_prompt, parse_policy
from llm.api_manager import APIManager


def run_reasoning(
    intent: str,
    report: Dict[str, Any],
    xapps: List[Dict[str, Any]],
    provider: str,
    model: Optional[str],
) -> Dict[str, Any]:
    prompt = build_prompt(intent, report, xapps)
    api = APIManager(provider_name=provider)
    response = api.generate(prompt, model=model)
    write_last_log(intent, prompt, response)
    parsed = parse_policy(response)
    if "policy" not in parsed:
        parsed["policy"] = {"enabledXApps": []}
    if "reasoning" not in parsed:
        parsed["reasoning"] = ""
    return parsed


def write_last_log(intent: str, prompt: str, response: str) -> None:
    log = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "intent": intent,
        "prompt": prompt,
        "llm_response": response,
    }
    log_path = Path(__file__).resolve().parent / "last_reasoning_log.json"
    log_path.write_text(
        json.dumps(log, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
