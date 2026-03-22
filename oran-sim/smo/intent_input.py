#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
意图输入模块：仅接收自然语言意图，不做解析
"""

from typing import Optional


INTENT_TEXT = "只调用xapp_drop_reducer"


def get_intent_text(intent: Optional[str] = None) -> str:
    _ = intent
    return str(INTENT_TEXT).strip()
