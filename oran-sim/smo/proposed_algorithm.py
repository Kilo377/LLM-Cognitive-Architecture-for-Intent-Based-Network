#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Proposed algorithm entry: select orchestration strategy.
"""

import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from baseline_reasoning import run_reasoning as run_llm_reasoning
from knowlegde_garph.knowledge_graph_builder import update_knowledge_graph
from knowlegde_garph.knowledge_graph_reasoning import (
    run_reasoning as run_graph_reasoning,
)


def load_config(path: Optional[Path] = None) -> Dict[str, Any]:
    base_dir = Path(__file__).resolve().parent
    cfg_path = path or (base_dir / "config.json")
    if not cfg_path.exists():
        return {"orchestrator": "llm", "provider": "ollama", "model": None}
    return json.loads(cfg_path.read_text(encoding="utf-8"))


def run(
    intent: str,
    report: Dict[str, Any],
    xapps: List[Dict[str, Any]],
    config: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    cfg = config or load_config()
    orchestrator = str(cfg.get("orchestrator", "llm")).lower()
    provider = cfg.get("provider", "ollama")
    model = cfg.get("model")

    deployed = []
    policy = report.get("policy", {})
    if isinstance(policy, dict):
        current = policy.get("current", {})
        if isinstance(current, dict):
            deployed = current.get("enabledXApps", [])

    if orchestrator == "graph":
        update_knowledge_graph()
        graph_out = run_graph_reasoning(
            intent,
            provider=provider,
            model=model,
            persist=True,
            deployed_xapps=deployed,
        )
        selected = graph_out.get("selected")
        selected_list = graph_out.get("selected_list", [])
        policy = {"enabledXApps": []}
        chosen = []
        if selected_list:
            for item in selected_list:
                xapp_id = item.get("xapp", "")
                if xapp_id.startswith("xapp:"):
                    xapp_id = xapp_id.split(":", 1)[1]
                if xapp_id:
                    chosen.append(xapp_id)
        elif selected:
            xapp_id = selected.get("xapp", "")
            if xapp_id.startswith("xapp:"):
                xapp_id = xapp_id.split(":", 1)[1]
            if xapp_id:
                chosen.append(xapp_id)
        if chosen:
            policy["enabledXApps"] = list(dict.fromkeys(chosen))
        return {
            "policy": policy,
            "reasoning": graph_out.get("reasoning", ""),
            "graph": graph_out,
        }

    parsed = run_llm_reasoning(intent, report, xapps, provider, model)
    return parsed
