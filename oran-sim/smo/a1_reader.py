#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
A1 数据读取模块：读取 non_rt_report.json，并按类别提供接口
"""

import json
from pathlib import Path
from typing import Any, Dict, List


def default_report_path() -> Path:
    base_dir = Path(__file__).resolve().parents[1]
    return base_dir / "bus_A1" / "non_rt_report.json"


def load_report(path=None) -> Dict[str, Any]:
    report_path = Path(path) if path else default_report_path()
    if not report_path.exists():
        raise FileNotFoundError(f"report not found: {report_path}")
    with report_path.open("r", encoding="utf-8") as f:
        return json.load(f)


def get_meta(report: Dict[str, Any]) -> Dict[str, Any]:
    return report.get("meta", {})


def get_policy(report: Dict[str, Any]) -> Dict[str, Any]:
    policy = report.get("policy", {})
    if isinstance(policy, dict):
        return policy.get("current", {})
    return {}


def get_control(report: Dict[str, Any]) -> Dict[str, Any]:
    return report.get("control", {})


def get_state(report: Dict[str, Any]) -> Dict[str, Any]:
    return report.get("state", {})


def get_kpi(report: Dict[str, Any]) -> Dict[str, Any]:
    return report.get("kpi", {})


def get_xapp_pool(report: Dict[str, Any]) -> List[Dict[str, Any]]:
    pool = report.get("xappPool", [])
    if isinstance(pool, list):
        return pool
    return []
