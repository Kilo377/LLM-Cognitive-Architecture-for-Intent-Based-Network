#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
意图输入模块：仅接收自然语言意图，不做解析
"""

from typing import Optional


def get_intent_text(intent: Optional[str] = None) -> str:
    if intent is None:
        return ""
    return str(intent).strip()
