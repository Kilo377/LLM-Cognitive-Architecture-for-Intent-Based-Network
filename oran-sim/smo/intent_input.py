#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
意图输入模块：仅接收自然语言意图，不做解析
"""

import json
from pathlib import Path
from typing import Optional


def _load_config_intent() -> Optional[str]:
    cfg_path = Path(__file__).resolve().parent / "config.json"
    if not cfg_path.exists():
        return None
    try:
        data = json.loads(cfg_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None
    value = data.get("intent_text")
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def get_intent_text(intent: Optional[str] = None) -> str:
    if isinstance(intent, str) and intent.strip():
        return intent.strip()
    cfg_intent = _load_config_intent()
    if cfg_intent:
        return cfg_intent
    return ""
