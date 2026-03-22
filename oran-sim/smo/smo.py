#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SMO 主入口：读取报告、选择意图、调用LLM并写出policy
"""

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List

from a1_reader import load_report
from intent_input import get_intent_text
from policy_orchestration import (
    build_prompt,
    parse_policy,
    write_policy,
    default_policy_path,
)
from llm.api_manager import APIManager


def default_report_path() -> Path:
    # 默认路径：oran-sim/bus_A1/non_rt_report.json
    base_dir = Path(__file__).resolve().parents[1]
    return base_dir / "bus_A1" / "non_rt_report.json"


def is_number(x: Any) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def is_matrix(value: Any) -> bool:
    # 判断二维数组（列表嵌套列表）
    if not isinstance(value, list) or not value:
        return False
    if not all(isinstance(row, list) for row in value):
        return False
    row_len = len(value[0])
    if row_len == 0:
        return False
    for row in value:
        if len(row) != row_len:
            return False
        if not all(is_number(x) for x in row):
            return False
    return True


def format_list(values: List[Any], max_len: int = 10) -> str:
    # 列表格式化：长列表做截断
    n = len(values)
    if n <= max_len:
        return str(values)
    head = values[: max_len // 2]
    tail = values[-max_len // 2 :]
    return f"{head} ... {tail} (len={n})"


def format_value(value: Any) -> str:
    # 统一格式化输出
    if isinstance(value, dict):
        return "{...}"
    if is_matrix(value):
        rows = len(value)
        cols = len(value[0]) if rows else 0
        sample = value[0][: min(cols, 6)]
        return f"matrix[{rows}x{cols}] sample_row0={sample}"
    if isinstance(value, list):
        return format_list(value)
    return str(value)


def print_header(title: str) -> None:
    print("\n" + "=" * 72)
    print(f"# {title}")
    print("=" * 72)


def print_dict_block(data: Dict[str, Any], indent: str = "") -> None:
    # 打印字典，遇到嵌套字典只显示占位
    if not data:
        print(f"{indent}未提供")
        return
    for k, v in data.items():
        print(f"{indent}{k}: {format_value(v)}")


def print_state_block(state: Dict[str, Any]) -> None:
    # state 分组打印
    if not state:
        print("未提供")
        return

    for key in ["topology", "ue", "cell", "channel"]:
        print(f"\n[{key}]")
        block = state.get(key, {})
        if isinstance(block, dict):
            print_dict_block(block, indent="  ")
        else:
            print(f"  {format_value(block)}")


def print_xapp_pool(pool: Any) -> None:
    # xApp pool 逐条打印
    if not pool:
        print("未提供")
        return
    if not isinstance(pool, list):
        print(format_value(pool))
        return

    for i, x in enumerate(pool, start=1):
        print(f"\n[xApp {i}]")
        if not isinstance(x, dict):
            print(f"  {format_value(x)}")
            continue
        for field in [
            "xapp_id",
            "name",
            "version",
            "description",
            "control_parameters",
            "kpi_objectives",
            "kpi_constraints",
            "expected_standalone_effect",
            "entry_point",
            "execution_type",
            "path",
            "status",
        ]:
            if field in x:
                print(f"  {field}: {format_value(x[field])}")


def print_report(data: Dict[str, Any]) -> None:
    print_header("元信息 meta")
    print_dict_block(data.get("meta", {}), indent="  ")

    print_header("当前策略 policy")
    policy = data.get("policy", {})
    if isinstance(policy, dict):
        print_dict_block(policy.get("current", {}), indent="  ")
    else:
        print(format_value(policy))

    print_header("控制参数 control")
    control = data.get("control", {})
    if isinstance(control, dict):
        print("[baseline]")
        print_dict_block(control.get("baseline", {}), indent="  ")
        print("\n[ctrl]")
        print_dict_block(control.get("ctrl", {}), indent="  ")
    else:
        print(format_value(control))

    print_header("网络观测 state")
    state = data.get("state", {})
    if isinstance(state, dict):
        print_state_block(state)
    else:
        print(format_value(state))

    print_header("KPI 指标")
    kpi = data.get("kpi", {})
    if isinstance(kpi, dict):
        print("[instant]")
        print_dict_block(kpi.get("instant", {}), indent="  ")
        print("\n[accumulated]")
        print_dict_block(kpi.get("accumulated", {}), indent="  ")
    else:
        print(format_value(kpi))

    print_header("xApp Pool")
    print_xapp_pool(data.get("xappPool", []))


def main(ran_intent: str) -> None:
    parser = argparse.ArgumentParser(description="SMO 主入口：读取报告 + LLM策略编排")
    parser.add_argument(
        "--report",
        type=str,
        default=str(default_report_path()),
        help="报告 JSON 路径（默认 oran-sim/bus_A1/non_rt_report.json）",
    )
    parser.add_argument(
        "--provider",
        type=str,
        default="ollama",
        help="LLM provider",
    )
    parser.add_argument(
        "--model",
        type=str,
        default=None,
        help="LLM model",
    )
    parser.add_argument(
        "--policy",
        type=str,
        default=str(default_policy_path()),
        help="policy输出路径（默认 oran-sim/bus_A1/non_rt_policy.json）",
    )
    parser.add_argument(
        "--print-report",
        action="store_true",
        help="打印报告内容",
    )
    args = parser.parse_args()

    report_path = Path(args.report)
    if not report_path.exists():
        print(f"文件不存在: {report_path}")
        return

    report = load_report(report_path)

    if args.print_report:
        print_report(report)

    intent = get_intent_text(ran_intent)

    prompt = build_prompt(intent, report, report.get("xappPool", []))
    api = APIManager(provider_name=args.provider)
    response = api.generate(prompt, model=args.model)
    parsed = parse_policy(response)
    policy = parsed.get("policy", {"enabledXApps": []})
    reasoning = parsed.get("reasoning", "")

    if reasoning:
        print(f"LLM 选择理由: {reasoning}")
    else:
        print("LLM 选择理由: (空)")

    write_policy(Path(args.policy), {"policy": policy})
    print(f"policy写入成功: {args.policy}")


if __name__ == "__main__":
    ran_intent = "打开所有xapp"
    main(ran_intent)
