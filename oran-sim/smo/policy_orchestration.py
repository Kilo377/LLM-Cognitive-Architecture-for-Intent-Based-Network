#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Policy Orchestration: 组装 prompt -> 调用 LLM -> 写 policy JSON
"""

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List

from a1_reader import load_report, get_xapp_pool, get_kpi, get_control, get_state
from intent_input import get_intent_text
from llm.api_manager import APIManager


def default_policy_path() -> Path:
    base_dir = Path(__file__).resolve().parents[1]
    return base_dir / "bus_A1" / "non_rt_policy.json"


def build_prompt(
    intent: str, report: Dict[str, Any], xapps: List[Dict[str, Any]]
) -> str:
    kpi = get_kpi(report)
    control = get_control(report)
    state = get_state(report)

    prompt = []
    prompt.append("你是RAN策略编排助手，请根据输入选择xApp集合。")
    prompt.append("输出必须是纯JSON，不允许其他文本。")
    prompt.append(
        'JSON格式：{"policy": {"enabledXApps": ["xapp_id", ...], "kpi_focus": ["kpi", ...]}, "reasoning": "..."}'
    )
    prompt.append("")
    prompt.append(f"意图: {intent}")
    prompt.append("")
    prompt.append("KPI摘要:")
    prompt.append(json.dumps(kpi, ensure_ascii=False))
    prompt.append("")
    prompt.append("控制参数摘要:")
    prompt.append(json.dumps(control, ensure_ascii=False))
    prompt.append("")
    prompt.append("状态摘要:")
    prompt.append(json.dumps(state, ensure_ascii=False))
    prompt.append("")
    prompt.append("xApp池:")
    prompt.append(json.dumps(xapps, ensure_ascii=False))
    prompt.append("")
    prompt.append("reasoning需为简短中文理由，不要包含多余格式。")
    prompt.append("kpi_focus请填写与意图相关的KPI名称列表。")
    prompt.append("请严格输出JSON。")

    return "\n".join(prompt)


def parse_policy(text: str) -> Dict[str, Any]:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"policy": {"enabledXApps": []}, "reasoning": ""}


def write_policy(path: Path, policy: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(policy, ensure_ascii=False)
    path.write_text(payload, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Policy orchestration using LLM")
    parser.add_argument("--intent", type=str, default="", help="自然语言意图")
    parser.add_argument("--report", type=str, default=None, help="报告路径")
    parser.add_argument(
        "--policy", type=str, default=str(default_policy_path()), help="policy输出路径"
    )
    parser.add_argument("--provider", type=str, default="ollama", help="LLM provider")
    parser.add_argument("--model", type=str, default=None, help="LLM model")
    args = parser.parse_args()

    report = load_report(args.report)
    intent = get_intent_text(args.intent)
    xapps = get_xapp_pool(report)

    prompt = build_prompt(intent, report, xapps)

    api = APIManager(provider_name=args.provider)
    response = api.generate(prompt, model=args.model)

    policy = parse_policy(response)
    write_policy(Path(args.policy), policy)


if __name__ == "__main__":
    main()
