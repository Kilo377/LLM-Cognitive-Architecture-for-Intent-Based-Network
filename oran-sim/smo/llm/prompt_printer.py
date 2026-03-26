#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Prompt printer: baseline_reasoning, graph prompts, and final chooser prompt.
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

SMO_DIR = Path(__file__).resolve().parents[1]
if str(SMO_DIR) not in sys.path:
    sys.path.append(str(SMO_DIR))

from a1_reader import load_report
from intent_input import get_intent_text
from policy_orchestration import build_prompt as build_baseline_prompt
from knowlegde_garph.knowledge_graph_reasoning import (
    build_target_prompt,
    build_path_prompt,
    build_paths,
    list_kpis,
    load_graph,
)


def default_report_path() -> Path:
    base_dir = Path(__file__).resolve().parents[2]
    return base_dir / "bus_A1" / "non_rt_report.json"


def _load_json_optional(path: Optional[str]) -> Any:
    if not path:
        return None
    p = Path(path)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def _split_csv(value: Optional[str]) -> List[str]:
    if not value:
        return []
    return [v.strip() for v in value.split(",") if v.strip()]


def _get_deployed_xapps(report: Dict[str, Any]) -> List[str]:
    policy = report.get("policy", {})
    if not isinstance(policy, dict):
        return []
    current = policy.get("current", {})
    if not isinstance(current, dict):
        return []
    deployed = current.get("enabledXApps", [])
    return deployed if isinstance(deployed, list) else []


def build_final_choice_prompt(
    intent: str,
    deployed_xapps: List[str],
    baseline_policy: Any,
    graph_policy: Any,
) -> str:
    baseline_block = (
        baseline_policy if baseline_policy is not None else "<BASELINE_POLICY_JSON>"
    )
    graph_block = graph_policy if graph_policy is not None else "<GRAPH_POLICY_JSON>"
    return (
        "You are the final policy selector. Choose the best policy proposal. "
        "Return ONLY JSON with a short reasoning string.\n\n"
        f"Intent: {intent}\n"
        f"Deployed xApps (current.enabledXApps): {deployed_xapps}\n"
        "Constraints:\n"
        "- Do not select already deployed xApps.\n"
        "- Resolve conflicts if both proposals overlap.\n\n"
        f"Baseline proposal: {json.dumps(baseline_block, ensure_ascii=False)}\n"
        f"Graph proposal: {json.dumps(graph_block, ensure_ascii=False)}\n\n"
        'Output format: {"policy": {"enabledXApps": [...], "kpi_focus": [...]}, "reasoning": "..."}\n'
    )


def print_block(title: str, text: str) -> None:
    print("\n" + "=" * 72)
    print(f"# {title}")
    print("=" * 72)
    print(text)


def main() -> None:
    parser = argparse.ArgumentParser(description="Print LLM prompts")
    parser.add_argument(
        "--report",
        type=str,
        default=str(default_report_path()),
        help="报告 JSON 路径",
    )
    parser.add_argument(
        "--mode",
        type=str,
        default="all",
        choices=["all", "llm", "graph"],
        help="选择打印 llm 或 graph prompt",
    )
    parser.add_argument("--intent", type=str, default=None, help="自然语言意图")
    parser.add_argument(
        "--targets",
        type=str,
        default=None,
        help="graph 目标 KPI 列表，用逗号分隔",
    )
    parser.add_argument(
        "--baseline-policy",
        type=str,
        default=None,
        help="baseline 候选 policy JSON 路径（可选）",
    )
    parser.add_argument(
        "--graph-policy",
        type=str,
        default=None,
        help="graph 候选 policy JSON 路径（可选）",
    )
    args = parser.parse_args()

    report_path = Path(args.report)
    if not report_path.exists():
        print(f"文件不存在: {report_path}")
        return

    report = load_report(report_path)
    intent = get_intent_text(args.intent)
    xapps = report.get("xappPool", [])
    deployed_xapps = _get_deployed_xapps(report)

    if args.mode in ("all", "llm"):
        baseline_prompt = build_baseline_prompt(intent, report, xapps)
        print_block("BASELINE_REASONING_PROMPT", baseline_prompt)

    if args.mode in ("all", "graph"):
        graph_path = (
            Path(__file__).resolve().parents[1]
            / "knowlegde_garph"
            / "knowledge_graph.json"
        )
        graph = load_graph(graph_path)
        kpis = list_kpis(graph)
        target_prompt = build_target_prompt(intent, kpis, deployed_xapps=deployed_xapps)
        print_block("GRAPH_TARGET_PROMPT", target_prompt)

        targets = _split_csv(args.targets)
        if not targets:
            targets = kpis
        paths = build_paths(graph, targets)
        path_prompt = build_path_prompt(
            intent,
            paths,
            graph=graph,
            deployed_xapps=deployed_xapps,
        )
        print_block("GRAPH_PATH_PROMPT", path_prompt)

    if args.mode == "graph":  # all , graph, llm
        baseline_policy = _load_json_optional(args.baseline_policy)
        graph_policy = _load_json_optional(args.graph_policy)
        final_prompt = build_final_choice_prompt(
            intent,
            deployed_xapps,
            baseline_policy,
            graph_policy,
        )
        print_block("FINAL_CHOICE_PROMPT", final_prompt)


if __name__ == "__main__":
    main()
