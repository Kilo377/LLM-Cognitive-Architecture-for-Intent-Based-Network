#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Generate Cytoscape-based HTML visualization and print summary.
"""

import json
from pathlib import Path
from typing import Dict, List, Tuple


def load_graph(path: Path) -> Dict:
    if not path.exists():
        raise FileNotFoundError(f"knowledge graph not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def summarize(graph: Dict) -> None:
    nodes = graph.get("nodes", [])
    edges = graph.get("edges", [])

    counts: Dict[str, int] = {}
    for n in nodes:
        t = n.get("type", "unknown")
        counts[t] = counts.get(t, 0) + 1

    edge_counts: Dict[str, int] = {}
    for e in edges:
        t = e.get("type", "unknown")
        edge_counts[t] = edge_counts.get(t, 0) + 1

    print("\n===== Knowledge Graph Summary =====")
    for k in sorted(counts.keys()):
        print(f"nodes[{k}]: {counts[k]}")
    for k in sorted(edge_counts.keys()):
        print(f"edges[{k}]: {edge_counts[k]}")

    print("\n===== Sample Paths (xapp-parameter-kpi) =====")
    paths = build_paths(graph)
    for p in paths:
        print(f"{p['xapp']} -> {p['parameter']} -> {p['kpi']}")


def build_paths(graph: Dict) -> List[Dict[str, str]]:
    param_edges = [e for e in graph.get("edges", []) if e.get("type") == "affects"]
    ctrl_edges = [e for e in graph.get("edges", []) if e.get("type") == "controls"]

    paths = []
    for pe in param_edges:
        param_id = pe.get("source")
        kpi_id = pe.get("target")
        for ce in ctrl_edges:
            if ce.get("target") == param_id:
                paths.append(
                    {
                        "xapp": ce.get("source"),
                        "parameter": param_id,
                        "kpi": kpi_id,
                    }
                )
    return paths


def _node_map(graph: Dict) -> Dict[str, Dict]:
    return {n.get("id"): n for n in graph.get("nodes", [])}


def _group_nodes(graph: Dict) -> Dict[str, List[Dict]]:
    grouped: Dict[str, List[Dict]] = {
        "rapp": [],
        "xapp": [],
        "parameter": [],
        "kpi": [],
    }
    for n in graph.get("nodes", []):
        t = n.get("type")
        if t in grouped:
            grouped[t].append(n)
    return grouped


def _build_node_meta(graph: Dict) -> Dict[str, Dict[str, str]]:
    nodes = _node_map(graph)
    edges = graph.get("edges", [])

    controls = {}
    affects = {}
    for e in edges:
        if e.get("type") == "controls":
            controls.setdefault(e.get("source"), []).append(e.get("target"))
        if e.get("type") == "affects":
            affects.setdefault(e.get("source"), []).append(e.get("target"))

    meta = {}
    for node_id, node in nodes.items():
        t = node.get("type")
        desc = ""
        if isinstance(node.get("meta"), dict):
            desc = node["meta"].get("description", "")

        entry = {"description": desc}
        if t == "xapp":
            params = controls.get(node_id, [])
            param_names = [nodes[p]["name"] for p in params if p in nodes]
            kpis = []
            for p in params:
                for k in affects.get(p, []):
                    if k in nodes:
                        kpis.append(nodes[k]["name"])
            entry["controlParams"] = ", ".join(param_names)
            entry["focusKpi"] = ", ".join(sorted(set(kpis)))
            entry["result"] = "-"
        meta[node_id] = entry
    return meta


def _build_positions(grouped: Dict[str, List[Dict]]) -> Dict[str, Dict[str, float]]:
    positions: Dict[str, Dict[str, float]] = {}
    layer_order = ["rapp", "xapp", "parameter", "kpi"]
    layer_y = {
        "rapp": 85,
        "xapp": 250,
        "parameter": 465,
        "kpi": 700,
    }

    for layer in layer_order:
        items = grouped.get(layer, [])
        if not items:
            continue
        count = len(items)
        gap = 170 if count <= 5 else max(120, 800 / max(count, 1))
        start_x = 80
        for i, n in enumerate(items):
            positions[n["id"]] = {"x": start_x + i * gap, "y": layer_y[layer]}
    return positions


def build_cytoscape_data(
    graph: Dict,
) -> Tuple[List[Dict], List[Dict], Dict[str, Dict[str, float]]]:
    nodes = graph.get("nodes", [])
    edges = graph.get("edges", [])

    grouped = _group_nodes(graph)
    if not grouped["rapp"]:
        demo = {
            "id": "rapp:intent_demo",
            "type": "rapp",
            "name": "rapp_intent_demo",
            "meta": {
                "description": "Intent demo rApp (placeholder).",
                "intent": "-",
                "result": "-",
            },
        }
        graph["nodes"].insert(0, demo)
        grouped = _group_nodes(graph)
        nodes = graph.get("nodes", [])

    node_meta = _build_node_meta(graph)
    positions = _build_positions(grouped)

    cy_nodes = []
    for n in nodes:
        nid = n.get("id")
        ntype = n.get("type")
        meta = node_meta.get(nid, {})
        label = n.get("name", nid)
        extra = {}
        if isinstance(n.get("meta"), dict):
            extra = n.get("meta")
        cy_nodes.append(
            {
                "data": {
                    "id": nid,
                    "label": label,
                    "type": ntype,
                    "description": meta.get("description", ""),
                    "intent": extra.get("intent", ""),
                    "result": meta.get("result", "-"),
                    "focusKpi": meta.get("focusKpi", ""),
                    "controlParams": meta.get("controlParams", ""),
                }
            }
        )

    rel_map = {
        "orchestrates": "control",
        "controls": "control",
        "affects": "impact",
        "targets": "expect",
    }
    cy_edges = []
    for i, e in enumerate(edges):
        rel = e.get("type")
        relation = rel_map.get(rel, "control")
        label = "controls" if relation == "control" else "impacts"
        if relation == "expect":
            label = "expects"
        cy_edges.append(
            {
                "data": {
                    "id": f"e{i}",
                    "source": e.get("source"),
                    "target": e.get("target"),
                    "relation": relation,
                    "label": label,
                }
            }
        )

    return cy_nodes, cy_edges, positions


def build_html(
    cy_nodes: List[Dict], cy_edges: List[Dict], positions: Dict[str, Dict[str, float]]
) -> str:
    html = f"""
<!DOCTYPE html>
<html lang=\"zh-CN\">
<head>
  <meta charset=\"UTF-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\" />
  <title>xApp Knowledge Graph</title>
  <script src=\"https://unpkg.com/cytoscape@3.26.0/dist/cytoscape.min.js\"></script>
  <style>
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; font-family: Arial, \"PingFang SC\", \"Microsoft YaHei\", sans-serif; background: #f5f7fb; color: #1f2937; }}
    .app {{ display: grid; grid-template-columns: 1fr 380px; height: 100vh; width: 100vw; }}
    .graph-wrap {{ position: relative; border-right: 1px solid #e5e7eb; background: linear-gradient(180deg, #f8fafc 0%, #eef3fb 100%); overflow: hidden; }}
    #cy {{ width: 100%; height: 100%; }}
    .layer-band {{ position: absolute; left: 0; right: 0; pointer-events: none; border-bottom: 1px dashed rgba(100, 116, 139, 0.25); }}
    .band-rapp {{ top: 0; height: 25%; background: rgba(139, 92, 246, 0.06); }}
    .band-xapp {{ top: 25%; height: 25%; background: rgba(59, 130, 246, 0.05); }}
    .band-param {{ top: 50%; height: 25%; background: rgba(249, 115, 22, 0.05); }}
    .band-kpi {{ top: 75%; height: 25%; background: rgba(34, 197, 94, 0.05); }}
    .layer-label {{ position: absolute; left: 18px; font-size: 13px; font-weight: 700; letter-spacing: 0.2px; color: #475569; pointer-events: none; background: rgba(255, 255, 255, 0.88); padding: 4px 10px; border-radius: 999px; box-shadow: 0 2px 10px rgba(15, 23, 42, 0.06); z-index: 5; }}
    .label-rapp {{ top: 16px; }}
    .label-xapp {{ top: calc(25% + 16px); }}
    .label-param {{ top: calc(50% + 16px); }}
    .label-kpi {{ top: calc(75% + 16px); }}
    .legend {{ position: absolute; right: 16px; top: 16px; z-index: 10; background: rgba(255, 255, 255, 0.94); backdrop-filter: blur(6px); border: 1px solid rgba(226, 232, 240, 0.9); border-radius: 16px; padding: 12px 14px; box-shadow: 0 10px 30px rgba(15, 23, 42, 0.08); min-width: 186px; }}
    .legend h3, .panel h2 {{ margin: 0 0 10px; font-size: 15px; }}
    .legend-row {{ display: flex; align-items: center; gap: 8px; margin: 8px 0; font-size: 13px; color: #475569; }}
    .swatch {{ width: 16px; height: 16px; border-radius: 6px; flex: 0 0 16px; }}
    .swatch.rapp {{ background: #8b5cf6; clip-path: polygon(50% 0%, 100% 38%, 82% 100%, 18% 100%, 0% 38%); border-radius: 0; }}
    .swatch.xapp {{ background: #2563eb; }}
    .swatch.param {{ background: #f97316; border-radius: 50%; }}
    .swatch.kpi {{ background: #22c55e; transform: rotate(45deg); border-radius: 2px; }}
    .line-swatch {{ width: 22px; height: 0; border-top: 2px solid #64748b; position: relative; }}
    .line-swatch::after {{ content: ""; position: absolute; right: -1px; top: -4px; border-left: 7px solid #64748b; border-top: 4px solid transparent; border-bottom: 4px solid transparent; }}
    .panel {{ background: #ffffff; padding: 22px 18px 18px; overflow-y: auto; }}
    .panel-card {{ border: 1px solid #e5e7eb; border-radius: 18px; padding: 14px; margin-bottom: 14px; background: #fff; box-shadow: 0 8px 24px rgba(15, 23, 42, 0.04); }}
    .muted {{ color: #64748b; font-size: 13px; line-height: 1.55; }}
    .panel-title {{ font-size: 18px; font-weight: 700; line-height: 1.35; margin-bottom: 6px; }}
    .badge-row {{ display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }}
    .badge {{ padding: 5px 10px; border-radius: 999px; font-size: 12px; font-weight: 700; line-height: 1.2; }}
    .badge.rapp {{ background: rgba(139, 92, 246, 0.12); color: #6d28d9; }}
    .badge.xapp {{ background: rgba(37, 99, 235, 0.12); color: #1d4ed8; }}
    .badge.param {{ background: rgba(249, 115, 22, 0.12); color: #c2410c; }}
    .badge.kpi {{ background: rgba(34, 197, 94, 0.12); color: #15803d; }}
    .badge.policy {{ background: rgba(15, 23, 42, 0.08); color: #0f172a; }}
    .section-title {{ margin: 14px 0 8px; font-size: 13px; font-weight: 700; color: #334155; }}
    .kv-list {{ display: grid; gap: 8px; }}
    .kv-item {{ padding: 10px 12px; border-radius: 12px; background: #f8fafc; font-size: 13px; line-height: 1.5; color: #334155; border: 1px solid #eef2f7; }}
    .kv-item strong {{ color: #0f172a; }}
    .hint {{ font-size: 12px; color: #64748b; margin-top: 8px; line-height: 1.5; }}
    .policy-box {{ margin-top: 12px; padding: 12px; border-radius: 14px; background: linear-gradient(180deg, #faf5ff 0%, #f8fafc 100%); border: 1px solid #e9d5ff; }}
    .policy-path {{ font-size: 13px; font-weight: 700; line-height: 1.65; color: #4c1d95; word-break: break-word; }}
    @media (max-width: 1200px) {{
      .app {{ grid-template-columns: 1fr; }}
      .panel {{ height: 44vh; border-top: 1px solid #e5e7eb; }}
      .graph-wrap {{ height: 56vh; }}
    }}
  </style>
</head>
<body>
  <div class=\"app\">
    <div class=\"graph-wrap\">
      <div class=\"layer-band band-rapp\"></div>
      <div class=\"layer-band band-xapp\"></div>
      <div class=\"layer-band band-param\"></div>
      <div class=\"layer-band band-kpi\"></div>
      <div class=\"layer-label label-rapp\">rApp Layer</div>
      <div class=\"layer-label label-xapp\">xApp Layer</div>
      <div class=\"layer-label label-param\">Parameter Layer</div>
      <div class=\"layer-label label-kpi\">KPI Layer</div>
      <div class=\"legend\">
        <h3>Graph Legend</h3>
        <div class=\"legend-row\"><span class=\"swatch rapp\"></span><span>rApp</span></div>
        <div class=\"legend-row\"><span class=\"swatch xapp\"></span><span>xApp</span></div>
        <div class=\"legend-row\"><span class=\"swatch param\"></span><span>Parameter</span></div>
        <div class=\"legend-row\"><span class=\"swatch kpi\"></span><span>KPI</span></div>
        <div class=\"legend-row\"><span class=\"line-swatch\"></span><span>关系边</span></div>
        <div class=\"legend-row\"><span style=\"width:22px;height:10px;border-radius:999px;background:#ec4899;display:inline-block;\"></span><span>Reasoning path</span></div>
      </div>
      <div id=\"cy\"></div>
    </div>

    <aside class=\"panel\">
      <div class=\"panel-card\">
        <h2>图谱推理详情</h2>
        <div id=\"details\">
          <div class=\"muted\">点击 rApp 节点可以触发基于图谱连接关系的 reasoning。系统会找到它期望的 KPI，再反向搜索所有可影响该 KPI 的 parameter 和 xApp，并高亮所有相关 path。右侧会给出一个可行 policy。</div>
          <div class=\"hint\">操作提示：点击 rApp 节点触发推理，点击其他节点查看完整属性，点击空白处恢复默认视图。</div>
        </div>
      </div>

      <div class=\"panel-card\">
        <h2>图谱说明</h2>
        <div class=\"muted\">本图谱包含四类节点：rApp、xApp、parameter、KPI。包含三类关系：rApp 期望 KPI，xApp 控制 parameter，parameter 影响 KPI。布局固定为四层，便于展示从意图到 KPI，再到参数与 xApp 的 reasoning 路径。</div>
      </div>
    </aside>
  </div>

  <script>
    const graphData = {{
      nodes: {json.dumps(cy_nodes)},
      edges: {json.dumps(cy_edges)}
    }};

    const positions = {json.dumps(positions)};

    const cy = cytoscape({{
      container: document.getElementById('cy'),
      elements: [...graphData.nodes, ...graphData.edges],
      layout: {{ name: 'preset', positions, padding: 50 }},
      minZoom: 0.42,
      maxZoom: 1.8,
      wheelSensitivity: 0.16,
      style: [
        {{ selector: 'node', style: {{
          label: 'data(label)',
          'text-wrap': 'wrap',
          'text-max-width': '155px',
          'text-valign': 'center',
          'text-halign': 'center',
          'font-size': 12,
          'font-weight': 700,
          color: '#ffffff',
          'overlay-opacity': 0,
          width: 'label',
          height: 'label',
          padding: '16px'
        }} }},
        {{ selector: 'node[type = "rapp"]', style: {{
          shape: 'hexagon',
          'background-color': '#8b5cf6',
          'border-width': 3,
          'border-color': '#ede9fe'
        }} }},
        {{ selector: 'node[type = "xapp"]', style: {{
          shape: 'round-rectangle',
          'background-color': '#2563eb',
          'border-width': 2,
          'border-color': '#dbeafe'
        }} }},
        {{ selector: 'node[type = "parameter"]', style: {{
          shape: 'ellipse',
          'background-color': '#f97316',
          'border-width': 2,
          'border-color': '#ffedd5'
        }} }},
        {{ selector: 'node[type = "kpi"]', style: {{
          shape: 'diamond',
          'background-color': '#22c55e',
          'border-width': 2,
          'border-color': '#dcfce7'
        }} }},
        {{ selector: 'edge', style: {{
          width: 2.2,
          'line-color': '#94a3b8',
          'target-arrow-color': '#94a3b8',
          'target-arrow-shape': 'triangle',
          'curve-style': 'bezier',
          'arrow-scale': 1,
          'overlay-opacity': 0,
          label: 'data(label)',
          'font-size': 10,
          color: '#475569',
          'text-background-color': '#ffffff',
          'text-background-opacity': 0.92,
          'text-background-padding': '2px',
          'text-background-shape': 'roundrectangle',
          'text-rotation': 'autorotate'
        }} }},
        {{ selector: 'edge[relation = "control"]', style: {{ 'line-style': 'solid' }} }},
        {{ selector: 'edge[relation = "impact"]', style: {{ 'line-style': 'dashed' }} }},
        {{ selector: 'edge[relation = "expect"]', style: {{
          'line-style': 'solid',
          'line-color': '#8b5cf6',
          'target-arrow-color': '#8b5cf6',
          width: 2.8,
          color: '#6d28d9'
        }} }},
        {{ selector: '.dimmed', style: {{ opacity: 0.12 }} }},
        {{ selector: '.reason-node', style: {{
          opacity: 1,
          'underlay-color': '#f9a8d4',
          'underlay-opacity': 0.4,
          'underlay-padding': '10px',
          'border-color': '#ec4899',
          'border-width': 4,
          'z-index': 999
        }} }},
        {{ selector: '.reason-edge', style: {{
          opacity: 1,
          width: 5,
          'line-color': '#ec4899',
          'target-arrow-color': '#ec4899',
          'line-style': 'solid',
          'z-index': 999,
          color: '#9d174d',
          'text-background-color': '#fff1f2',
          'text-background-opacity': 1,
          'text-background-padding': '3px'
        }} }},
        {{ selector: '.selected-focus', style: {{
          opacity: 1,
          'border-color': '#0f172a',
          'border-width': 4,
          'line-color': '#0f172a',
          'target-arrow-color': '#0f172a',
          'z-index': 1000
        }} }}
      ]
    }});

    const detailsEl = document.getElementById('details');
    function resetDetails() {{
      detailsEl.innerHTML = `
        <div class="muted">点击 rApp 节点可以触发基于图谱连接关系的 reasoning。系统会找到它期望的 KPI，再反向搜索所有可影响该 KPI 的 parameter 和 xApp，并高亮所有相关 path。右侧会给出一个可行 policy。</div>
        <div class="hint">操作提示：点击 rApp 节点触发推理，点击其他节点查看完整属性，点击空白处恢复默认视图。</div>
      `;
    }}

    function renderNodeDetails(node) {{
      const data = node.data();
      const typeClass = data.type === 'parameter' ? 'param' : data.type;
      const incomers = node.incomers('node').map(n => n.data('label'));
      const outgoers = node.outgoers('node').map(n => n.data('label'));

      let extra = `
        <div class="section-title">节点说明</div>
        <div class="kv-list">
          <div class="kv-item"><strong>描述：</strong>${{data.description || '-'}}</div>
        </div>
      `;

      if (data.type === 'rapp') {{
        extra = `
          <div class="section-title">rApp 属性</div>
          <div class="kv-list">
            <div class="kv-item"><strong>自然语言意图：</strong>${{data.intent || '-'}}</div>
            <div class="kv-item"><strong>说明：</strong>${{data.description || '-'}}</div>
            <div class="kv-item"><strong>目标：</strong>${{data.result || '-'}}</div>
          </div>
        `;
      }}

      if (data.type === 'xapp') {{
        extra = `
          <div class="section-title">xApp 属性</div>
          <div class="kv-list">
            <div class="kv-item"><strong>描述：</strong>${{data.description || '-'}}</div>
            <div class="kv-item"><strong>关注 KPI：</strong>${{data.focusKpi || '-'}}</div>
            <div class="kv-item"><strong>控制参数：</strong>${{data.controlParams || '-'}}</div>
            <div class="kv-item"><strong>影响最大 KPI：</strong>${{data.result || '-'}}</div>
          </div>
        `;
      }}

      detailsEl.innerHTML = `
        <div class="panel-title">${{data.label}}</div>
        <div class="badge-row">
          <span class="badge ${{typeClass}}">${{data.type}}</span>
        </div>
        ${{extra}}
        <div class="section-title">关系</div>
        <div class="kv-list">
          <div class="kv-item"><strong>上游：</strong>${{incomers.length ? incomers.join('，') : '无'}}</div>
          <div class="kv-item"><strong>下游：</strong>${{outgoers.length ? outgoers.join('，') : '无'}}</div>
        </div>
      `;
    }}

    function renderEdgeDetails(edge) {{
      const data = edge.data();
      const source = edge.source().data('label');
      const target = edge.target().data('label');
      let relationText = '关系';
      if (data.relation === 'control') relationText = 'xApp 控制 parameter';
      if (data.relation === 'impact') relationText = 'parameter 影响 KPI';
      if (data.relation === 'expect') relationText = 'rApp 期望 KPI 提升';

      detailsEl.innerHTML = `
        <div class="panel-title">${{source}} → ${{target}}</div>
        <div class="badge-row">
          <span class="badge ${{data.relation === 'expect' ? 'rapp' : (data.relation === 'impact' ? 'kpi' : 'xapp')}}">${{data.relation}}</span>
        </div>
        <div class="section-title">关系说明</div>
        <div class="kv-list">
          <div class="kv-item"><strong>语义：</strong>${{relationText}}</div>
          <div class="kv-item"><strong>标签：</strong>${{data.label}}</div>
          <div class="kv-item"><strong>起点：</strong>${{source}}</div>
          <div class="kv-item"><strong>终点：</strong>${{target}}</div>
        </div>
      `;
    }}

    function clearStyles() {{
      cy.elements().removeClass('dimmed');
      cy.elements().removeClass('reason-node');
      cy.elements().removeClass('reason-edge');
      cy.elements().removeClass('selected-focus');
    }}

    function highlightSimple(ele) {{
      clearStyles();
      cy.elements().addClass('dimmed');
      ele.removeClass('dimmed').addClass('selected-focus');
      ele.neighborhood().removeClass('dimmed').addClass('selected-focus');
      ele.connectedEdges().removeClass('dimmed').addClass('selected-focus');
    }}

    function findReasoningPathsFromRapp(rappNode) {{
      const expectEdges = rappNode.outgoers('edge[relation = "expect"]');
      if (!expectEdges.length) return null;

      const targetKpi = expectEdges.targets()[0];
      const impactEdges = targetKpi.incomers('edge[relation = "impact"]');
      const parameters = impactEdges.sources();
      const controlEdges = parameters.incomers('edge[relation = "control"]');
      const xapps = controlEdges.sources();

      const relatedEdges = cy.collection();
      const relatedNodes = cy.collection();

      relatedNodes.merge(rappNode);
      relatedNodes.merge(targetKpi);
      relatedEdges.merge(expectEdges);

      parameters.forEach(param => {{
        relatedNodes.merge(param);
        const pToKpi = param.outgoers(`edge[relation = "impact"][target = "${{targetKpi.id()}}"]`);
        relatedEdges.merge(pToKpi);

        const incomingControls = param.incomers('edge[relation = "control"]');
        incomingControls.forEach(ctrl => {{
          const xapp = ctrl.source();
          relatedNodes.merge(xapp);
          relatedEdges.merge(ctrl);
        }});
      }});

      return {{
        rappNode,
        targetKpi,
        parameters,
        xapps,
        relatedEdges,
        relatedNodes,
      }};
    }}

    function renderReasoning(result) {{
      const xappNames = [];
      result.xapps.forEach(x => xappNames.push(x.data('label')));
      const paramNames = [];
      result.parameters.forEach(p => paramNames.push(p.data('label')));

      detailsEl.innerHTML = `
        <div class="panel-title">${{result.rappNode.data('label')}} 的 reasoning 结果</div>
        <div class="badge-row">
          <span class="badge rapp">intent</span>
          <span class="badge kpi">target KPI</span>
          <span class="badge policy">policy</span>
        </div>
        <div class="section-title">推理摘要</div>
        <div class="kv-list">
          <div class="kv-item"><strong>自然语言意图：</strong>${{result.rappNode.data('intent') || '-'}}</div>
          <div class="kv-item"><strong>目标 KPI：</strong>${{result.targetKpi.data('label')}}</div>
          <div class="kv-item"><strong>可影响 KPI 的 parameter：</strong>${{paramNames.join('，') || '无'}}</div>
          <div class="kv-item"><strong>可用 xApp：</strong>${{xappNames.join('，') || '无'}}</div>
        </div>
      `;
    }}

    function applyReasoningHighlight(result) {{
      clearStyles();
      cy.elements().addClass('dimmed');
      result.relatedNodes.removeClass('dimmed').addClass('reason-node');
      result.relatedEdges.removeClass('dimmed').addClass('reason-edge');
      result.rappNode.removeClass('reason-node').addClass('selected-focus');
      result.targetKpi.removeClass('reason-node').addClass('selected-focus');
    }}

    cy.on('tap', 'node', evt => {{
      const node = evt.target;
      if (node.data('type') === 'rapp') {{
        const result = findReasoningPathsFromRapp(node);
        if (result) {{
          applyReasoningHighlight(result);
          renderReasoning(result);
        }} else {{
          highlightSimple(node);
          renderNodeDetails(node);
        }}
        return;
      }}

      highlightSimple(node);
      renderNodeDetails(node);
    }});

    cy.on('tap', 'edge', evt => {{
      const edge = evt.target;
      clearStyles();
      cy.elements().addClass('dimmed');
      edge.removeClass('dimmed').addClass('selected-focus');
      edge.connectedNodes().removeClass('dimmed').addClass('selected-focus');
      renderEdgeDetails(edge);
    }});

    cy.on('tap', evt => {{
      if (evt.target === cy) {{
        clearStyles();
        resetDetails();
      }}
    }});

    cy.fit(cy.elements(), 40);
  </script>
</body>
</html>
"""
    return html


def write_html(graph: Dict, out_path: Path) -> None:
    cy_nodes, cy_edges, positions = build_cytoscape_data(graph)
    html = build_html(cy_nodes, cy_edges, positions)
    out_path.write_text(html, encoding="utf-8")


def main() -> None:
    base_dir = Path(__file__).resolve().parent
    graph_path = base_dir / "knowledge_graph.json"
    out_path = base_dir / "knowledge_graph.html"

    graph = load_graph(graph_path)
    write_html(graph, out_path)
    summarize(graph)
    print(f"\nHTML written: {out_path}")


if __name__ == "__main__":
    main()
