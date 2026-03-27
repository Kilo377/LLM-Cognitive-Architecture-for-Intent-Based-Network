#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Knowledge graph reasoning utilities for rApp orchestration.
"""

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

BASE_DIR = Path(__file__).resolve().parent
SMO_DIR = BASE_DIR.parent
if str(SMO_DIR) not in sys.path:
    sys.path.append(str(SMO_DIR))

from llm.api_manager import APIManager


def load_graph(path: Path) -> Dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"knowledge graph not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def save_graph(graph: Dict[str, Any], path: Path) -> None:
    path.write_text(json.dumps(graph, ensure_ascii=False, indent=2), encoding="utf-8")


def list_kpis(graph: Dict[str, Any]) -> List[str]:
    out = []
    for node in graph.get("nodes", []):
        if node.get("type") == "kpi":
            out.append(node.get("name"))
    return sorted(set(out))


def build_target_prompt(
    intent: str, kpis: List[str], deployed_xapps: Optional[List[str]] = None
) -> str:
    deployed_xapps = deployed_xapps or []
    return (
        "You are selecting KPI targets for a new rApp. "
        "Return ONLY a JSON array of KPI names chosen from the list. "
        "No explanations, no extra text.\n\n"
        f"Intent: {intent}\n"
        f"KPI list: {kpis}\n"
        f"Deployed xApps (current.enabledXApps): {deployed_xapps}\n"
        "Constraints:\n"
        "- Avoid selecting targets that would require already deployed xApps.\n"
        "- Consider potential conflicts across targets.\n"
        "Output format: ["
        "KPI1"
        ", "
        "KPI2"
        "]\n"
    )


def build_reasoning_paths(
    paths: List[Dict[str, str]],
    graph: Optional[Dict[str, Any]] = None,
) -> List[str]:
    if not graph:
        return [
            f"{p.get('xapp', '')} -> param:scheduling.selectedUE -> {p.get('kpi', '')}"
            for p in paths
        ]

    node_index = {n.get("id"): n for n in graph.get("nodes", []) if n.get("id")}
    display = []
    for p in paths:
        xapp_id = p.get("xapp", "")
        kpi_id = p.get("kpi", "")
        xapp_node = node_index.get(xapp_id, {})
        xapp_name = xapp_node.get("name") or xapp_id
        display.append(f"{xapp_name} -> param:scheduling.selectedUE -> {kpi_id}")
    return display


def build_xapp_descriptions(
    paths: List[Dict[str, str]],
    graph: Optional[Dict[str, Any]] = None,
) -> Dict[str, str]:
    if not graph:
        return {}
    node_index = {n.get("id"): n for n in graph.get("nodes", []) if n.get("id")}
    out = {}
    for p in paths:
        xapp_id = p.get("xapp", "")
        if not xapp_id or xapp_id in out:
            continue
        node = node_index.get(xapp_id, {})
        name = node.get("name") or xapp_id
        meta = node.get("meta") if isinstance(node.get("meta"), dict) else {}
        desc = ""
        if isinstance(meta, dict):
            desc = meta.get("description") or ""
        if isinstance(desc, str) and desc.strip():
            out[name] = desc.strip()
    return out


def build_xapp_id_map(
    paths: List[Dict[str, str]],
    graph: Optional[Dict[str, Any]] = None,
) -> Dict[str, str]:
    if not graph:
        return {}
    node_index = {n.get("id"): n for n in graph.get("nodes", []) if n.get("id")}
    out = {}
    for p in paths:
        xapp_id = p.get("xapp", "")
        if not xapp_id or xapp_id in out:
            continue
        node = node_index.get(xapp_id, {})
        name = node.get("name") or xapp_id
        out[xapp_id] = name
    return out


def build_path_prompt(
    intent: str,
    paths: List[Dict[str, str]],
    graph: Optional[Dict[str, Any]] = None,
    deployed_xapps: Optional[List[str]] = None,
) -> str:
    deployed_xapps = deployed_xapps or []
    display_paths = build_reasoning_paths(paths, graph)
    xapp_desc = build_xapp_descriptions(paths, graph)
    xapp_id_map = build_xapp_id_map(paths, graph)
    return (
        "Select the best xApp path(s) for the intent. "
        "Return ONLY JSON. No explanations or extra text.\n\n"
        f"Intent: {intent}\n"
        f"这是目前的一些备选的路径, 以及其控制链路: {json.dumps(display_paths, ensure_ascii=False)}\n"
        f"xApp descriptions: {json.dumps(xapp_desc, ensure_ascii=False)}\n"
        f"xApp id to name: {json.dumps(xapp_id_map, ensure_ascii=False)}\n"
        f"Deployed xApps (current.enabledXApps): {deployed_xapps}\n"
        "Constraints:\n"
        "- Do not choose paths with already deployed xApps.\n"
        "- Consider potential conflicts across selected paths.\n"
        "- You may choose multiple paths if helpful. but should avoid conflict as possible\n"
        "- The `xapp` field MUST use xapp_id (e.g., xapp_drop_reducer), not the name.\n"
        "- Add a short `reasoning` string.\n"
        'Output format (single): {"xapp":"xapp_drop_reducer", "parameter":..., "kpi":..., "reasoning":"..."}\n'
        "Output format (multiple): [{...}, {...}]\n"
    )


def _extract_json_array(text: str) -> Optional[List[str]]:
    try:
        data = json.loads(text)
        if isinstance(data, list):
            return [str(x) for x in data]
    except Exception:
        pass
    return None


def _extract_json_payload(text: str) -> Optional[Any]:
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        pass

    lb = text.find("[")
    rb = text.rfind("]")
    if lb != -1 and rb != -1 and rb > lb:
        try:
            return json.loads(text[lb : rb + 1])
        except Exception:
            pass

    lb = text.find("{")
    rb = text.rfind("}")
    if lb != -1 and rb != -1 and rb > lb:
        try:
            return json.loads(text[lb : rb + 1])
        except Exception:
            pass

    return None


def infer_targets_from_intent(
    intent: str,
    kpis: List[str],
    provider: str = "ollama",
    model: Optional[str] = None,
    deployed_xapps: Optional[List[str]] = None,
) -> List[str]:
    prompt = build_target_prompt(intent, kpis, deployed_xapps=deployed_xapps)
    api = APIManager(provider_name=provider)
    response = api.generate(prompt, model=model)
    targets = _extract_json_array(response)
    if targets:
        return [t for t in targets if t in kpis]
    return []


def add_rapp_node(
    graph: Dict[str, Any], rapp_id: str, name: str, intent: str = ""
) -> None:
    for node in graph.get("nodes", []):
        if node.get("id") == rapp_id:
            if isinstance(node.get("meta"), dict):
                node["meta"]["intent"] = intent
                node["meta"]["description"] = "Intent rApp"
            return
    graph.setdefault("nodes", []).append(
        {
            "id": rapp_id,
            "type": "rapp",
            "name": name,
            "meta": {
                "description": "Intent rApp",
                "intent": intent,
                "result": "",
            },
        }
    )


def add_edge(graph: Dict[str, Any], source: str, target: str, rel: str) -> None:
    edges = graph.setdefault("edges", [])
    for e in edges:
        if (
            e.get("source") == source
            and e.get("target") == target
            and e.get("type") == rel
        ):
            return
    edges.append({"source": source, "target": target, "type": rel})


def build_paths(graph: Dict[str, Any], target_kpis: List[str]) -> List[Dict[str, str]]:
    kpi_nodes = {
        n["name"]: n["id"] for n in graph.get("nodes", []) if n.get("type") == "kpi"
    }
    param_edges = [e for e in graph.get("edges", []) if e.get("type") == "affects"]
    ctrl_edges = [e for e in graph.get("edges", []) if e.get("type") == "controls"]

    paths = []
    for kpi_name in target_kpis:
        kpi_id = kpi_nodes.get(kpi_name)
        if not kpi_id:
            continue
        params = [e["source"] for e in param_edges if e["target"] == kpi_id]
        for param_id in params:
            xapps = [e["source"] for e in ctrl_edges if e["target"] == param_id]
            for xapp_id in xapps:
                paths.append(
                    {
                        "xapp": xapp_id,
                        "parameter": param_id,
                        "kpi": kpi_id,
                    }
                )
    return paths


def select_path_with_llm(
    intent: str,
    paths: List[Dict[str, str]],
    provider: str = "ollama",
    model: Optional[str] = None,
    graph: Optional[Dict[str, Any]] = None,
    deployed_xapps: Optional[List[str]] = None,
) -> Dict[str, Any]:
    result = {
        "selected": None,
        "selected_list": [],
        "llm_response": "",
        "reasoning": "",
    }
    if not paths:
        return result
    prompt = build_path_prompt(
        intent,
        paths,
        graph=graph,
        deployed_xapps=deployed_xapps,
    )
    api = APIManager(provider_name=provider)
    response = api.generate(prompt, model=model)
    result["llm_response"] = response
    try:
        data = _extract_json_payload(response)
        if isinstance(data, list):
            filtered = [
                d
                for d in data
                if isinstance(d, dict) and {"xapp", "parameter", "kpi"} <= set(d.keys())
            ]
            if filtered:
                result["selected_list"] = filtered
                result["selected"] = filtered[0]
                reasoning = filtered[0].get("reasoning", "")
                if isinstance(reasoning, str):
                    result["reasoning"] = reasoning
                return result
        if isinstance(data, dict) and {"xapp", "parameter", "kpi"} <= set(data.keys()):
            result["selected"] = data
            reasoning = data.get("reasoning", "")
            if isinstance(reasoning, str):
                result["reasoning"] = reasoning
            return result
    except Exception:
        pass
    result["selected"] = paths[0]
    return result


def run_reasoning(
    intent: str,
    provider: str = "ollama",
    model: Optional[str] = None,
    graph_path: Optional[Path] = None,
    persist: bool = False,
    deployed_xapps: Optional[List[str]] = None,
) -> Dict[str, Any]:
    graph_path = graph_path or (BASE_DIR / "knowledge_graph.json")
    graph = load_graph(graph_path)

    kpis = list_kpis(graph)
    targets = infer_targets_from_intent(
        intent, kpis, provider=provider, model=model, deployed_xapps=deployed_xapps
    )

    rapp_id = f"rapp:{normalize_rapp_id(intent)}"
    add_rapp_node(graph, rapp_id, "Intent rApp", intent=intent)

    for k in targets:
        add_edge(graph, rapp_id, f"kpi:{normalize_rapp_id(k)}", "targets")

    paths = build_paths(graph, targets)
    selected_out = select_path_with_llm(
        intent,
        paths,
        provider=provider,
        model=model,
        graph=graph,
        deployed_xapps=deployed_xapps,
    )
    selected = selected_out.get("selected")
    selected_list = selected_out.get("selected_list", [])
    reasoning = selected_out.get("reasoning", "")

    if selected_list:
        for item in selected_list:
            add_edge(graph, rapp_id, item.get("xapp", ""), "orchestrates")
    elif selected:
        add_edge(graph, rapp_id, selected.get("xapp", ""), "orchestrates")

    if selected_list:
        sel_ids = [item.get("xapp", "") for item in selected_list]
        sel_text = ", ".join([s for s in sel_ids if s])
    elif selected:
        sel_text = selected.get("xapp", "")
    else:
        sel_text = ""

    if sel_text:
        for node in graph.get("nodes", []):
            if node.get("id") == rapp_id and isinstance(node.get("meta"), dict):
                node["meta"]["result"] = f"selected {sel_text}"
                break

    if persist:
        save_graph(graph, graph_path)

    return {
        "rapp": rapp_id,
        "targets": targets,
        "paths": paths,
        "selected": selected,
        "selected_list": selected_list,
        "reasoning": reasoning,
        "llm_response": selected_out.get("llm_response", ""),
        "graph_path": str(graph_path),
    }


def normalize_rapp_id(text: str) -> str:
    out = []
    for ch in str(text).strip().lower():
        if ch.isalnum():
            out.append(ch)
        else:
            out.append("_")
    s = "".join(out).strip("_")
    while "__" in s:
        s = s.replace("__", "_")
    return s
