#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Knowledge graph builder for rApp/xApp orchestration.
"""

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Tuple, Optional


BASE_KPI_MAP = {
    "xapp_capacity_booster": ["Throughput", "DropRatio"],
    "xapp_drop_reducer": ["DropRatio", "BLER"],
    "xapp_fairness_scheduler": ["Fairness"],
    "xapp_fairness_no_thr_loss": ["Fairness", "Top10Share"],
    "xapp_fairness_no_drop_loss": ["Fairness", "DropRatio", "Top10Share"],
    "xapp_interference_mitigator": ["Interference", "BLER"],
    "xapp_mobility_balancer": ["HandoverDelay"],
    "xapp_stability_guard": ["HO Count"],
    "xapp_throughput_maximizer": ["Throughput"],
}


def normalize_id(text: str) -> str:
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


def list_xapp_registries(xapps_root: Path) -> List[Path]:
    return sorted(xapps_root.glob("*/registry.json"))


def load_existing_graph(path: Path) -> Dict:
    if not path.exists():
        return {"nodes": [], "edges": []}
    return json.loads(path.read_text(encoding="utf-8"))


def read_registry(path: Path) -> Dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def extract_control_params(reg: Dict) -> List[str]:
    params = reg.get("control_parameters", [])
    out: List[str] = []
    if isinstance(params, list):
        for p in params:
            if isinstance(p, str):
                out.append(p)
            elif isinstance(p, dict) and "parameter" in p:
                out.append(p["parameter"])
    return out


def add_node(
    nodes: Dict[str, Dict], node_id: str, node_type: str, name: str, meta=None
) -> None:
    if node_id in nodes:
        return
    entry = {"id": node_id, "type": node_type, "name": name}
    if meta:
        entry["meta"] = meta
    nodes[node_id] = entry


def add_edge(
    edges: Dict[Tuple[str, str, str], Dict], source: str, target: str, rel: str
) -> None:
    key = (source, target, rel)
    if key in edges:
        return
    edges[key] = {"source": source, "target": target, "type": rel}


def build_graph(xapps_root: Path, existing: Dict) -> Dict:
    nodes: Dict[str, Dict] = {}
    edges: Dict[Tuple[str, str, str], Dict] = {}

    for n in existing.get("nodes", []):
        if n.get("type") == "rapp":
            add_node(nodes, n.get("id", ""), "rapp", n.get("name", ""), n.get("meta"))

    for e in existing.get("edges", []):
        if e.get("type") in {"targets", "orchestrates"}:
            add_edge(edges, e.get("source", ""), e.get("target", ""), e.get("type"))

    for reg_path in list_xapp_registries(xapps_root):
        reg = read_registry(reg_path)
        xapp_id = reg.get("xapp_id", reg_path.parent.name)
        name = reg.get("name", xapp_id)
        desc = reg.get("description", "")

        xapp_node = f"xapp:{xapp_id}"
        add_node(nodes, xapp_node, "xapp", name, {"description": desc})

        params = extract_control_params(reg)
        for p in params:
            param_id = f"param:{p}"
            add_node(nodes, param_id, "parameter", p)
            add_edge(edges, xapp_node, param_id, "controls")

        kpi_list = BASE_KPI_MAP.get(xapp_id, [])
        for kpi in kpi_list:
            kpi_id = f"kpi:{normalize_id(kpi)}"
            add_node(nodes, kpi_id, "kpi", kpi)
            for p in params:
                param_id = f"param:{p}"
                add_edge(edges, param_id, kpi_id, "affects")

    graph = {
        "meta": {
            "schema": "knowledge_graph",
            "generatedAt": datetime.now(timezone.utc).isoformat(),
        },
        "nodes": list(nodes.values()),
        "edges": list(edges.values()),
    }
    return graph


def write_graph(graph: Dict, path: Path) -> None:
    path.write_text(json.dumps(graph, ensure_ascii=False, indent=2), encoding="utf-8")


def update_knowledge_graph(graph_path: Optional[Path] = None) -> Path:
    base_dir = Path(__file__).resolve().parent
    xapps_root = base_dir.parent.parent / "xapps"
    graph_path = graph_path or (base_dir / "knowledge_graph.json")

    existing = load_existing_graph(graph_path)
    graph = build_graph(xapps_root, existing)
    write_graph(graph, graph_path)
    return graph_path


if __name__ == "__main__":
    out_path = update_knowledge_graph()
    print(f"knowledge graph written: {out_path}")
