# local_tools.py
# 本地工具集合：基础工具 + O-RAN 实验日志工具

from typing import Any, Dict
import os
import json

# ====== 日志路径配置（根据实际情况修改） ======
# 历史实验日志（每行一个 JSON）
EXPERIMENT_LOG_PATH = r"D:\oran_logs\experiments.jsonl"
# 元认知候选策略输出
CANDIDATE_FILE_PATH = r"D:\oran_logs\candidate_policies.jsonl"


# ===== 基础工具：加法 & 读文本文件 =====

def tool_add(a: int, b: int) -> str:
    return f"{a} + {b} = {a + b}"


def tool_read_text(path: str) -> str:
    if not os.path.exists(path):
        return f"[ERROR] file not found: {path}"
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception as e:
        return f"[ERROR] cannot read file {path}: {e}"


# ===== 实验日志相关工具 =====

def _format_experiment_record(rec: Dict[str, Any]) -> str:
    """
    把一条结构化实验记录格式化成自然语言摘要：
    [实验 exp_001]
    - 意图: ...
    - 关键策略: ...
    - 结果: ...
    """
    exp_id = rec.get("exp_id", "?")
    intent = rec.get("intent_desc", "")

    pol = rec.get("policy", {})
    nonrt = pol.get("nonRT_params", {})
    nearrt = pol.get("nearRT_params", {})
    beam = pol.get("beam_params", {})

    kpi = rec.get("kpi", {})
    sum_tput = kpi.get("sum_tput_Mbps", "?")
    ue_5p = kpi.get("ue_tput_5p", "?")
    energy = kpi.get("estimated_energy_W", "?")
    sleep_ratio = kpi.get("sleep_ratio_small_cells", "?")

    lines = []
    lines.append(f"[实验 {exp_id}]")
    lines.append(f"- 意图: {intent}")

    lines.append("- 关键策略:")
    lines.append(
        "  - non-RT: "
        f"宏轻载阈值={nonrt.get('macro_load_low_thresh','?')}, "
        f"高载阈值={nonrt.get('macro_load_high_thresh','?')}, "
        f"开启小小区数上限={nonrt.get('max_small_cells_on','?')}, "
        f"探索率={nonrt.get('epsilon_greedy','?')}"
    )
    lines.append(
        "  - near-RT: "
        f"Video/URLLC 迁移门限={nearrt.get('video_to_small_threshold','?')}, "
        f"Gaming 迁移门限={nearrt.get('gaming_to_small_threshold','?')}, "
        f"Voice 保持倾向={nearrt.get('voice_stickiness','?')}, "
        f"探索率={nearrt.get('epsilon_greedy','?')}"
    )
    lines.append(
        "  - Beam: "
        f"每小区波束数={beam.get('numBeamsPerCell','?')}, "
        f"策略={beam.get('scheme','?')}"
    )

    lines.append("- 结果:")
    lines.append(f"  - 总下行吞吐 ≈ {sum_tput} Mbps")
    lines.append(f"  - 5% UE 吞吐 ≈ {ue_5p} Mbps")
    lines.append(f"  - 估算能耗 ≈ {energy} W")
    lines.append(f"  - 小小区休眠比例 ≈ {sleep_ratio}")

    return "\n".join(lines)


def tool_get_policy_history(intent_pattern: str, max_records: int = 20) -> str:
    """
    根据意图关键字，从 experiments.jsonl 中筛选历史实验，
    并返回一个自然语言摘要，供元认知 agent 阅读。
    """
    matches = []
    try:
        with open(EXPERIMENT_LOG_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                rec = json.loads(line)
                if intent_pattern in rec.get("intent_desc", ""):
                    matches.append(rec)
                    if len(matches) >= max_records:
                        break
    except FileNotFoundError:
        return f"[ERROR] experiment log file not found: {EXPERIMENT_LOG_PATH}"
    except Exception as e:
        return f"[ERROR] reading experiment log failed: {e}"

    if not matches:
        return f"未找到包含 '{intent_pattern}' 的历史实验记录。"

    blocks = [_format_experiment_record(r) for r in matches]
    return "\n\n".join(blocks)


def tool_save_policy_candidate(intent_id: str, proposal_json: str) -> str:
    """
    把元认知 agent 生成的策略候选追加写入一个文件。
    proposal_json 建议是一个 JSON 字符串（包含高层建议）。
    """
    record = {
        "intent_id": intent_id,
        "proposal_json": proposal_json,
    }
    try:
        os.makedirs(os.path.dirname(CANDIDATE_FILE_PATH), exist_ok=True)
        with open(CANDIDATE_FILE_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:
        return f"[ERROR] failed to save candidate policy: {e}"

    return f"候选策略已保存到 {CANDIDATE_FILE_PATH}, intent_id={intent_id}"


# ===== 工具注册表 =====

LOCAL_TOOL_IMPLS: Dict[str, Any] = {
    "add": tool_add,
    "read_text": tool_read_text,
    "get_policy_history": tool_get_policy_history,
    "save_policy_candidate": tool_save_policy_candidate,
}

# 提供给 LLM 的 tools schema
TOOLS_SPEC = [
    {
        "type": "function",
        "function": {
            "name": "add",
            "description": "计算两个整数的和",
            "parameters": {
                "type": "object",
                "properties": {
                    "a": {"type": "integer", "description": "第一个加数"},
                    "b": {"type": "integer", "description": "第二个加数"},
                },
                "required": ["a", "b"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_text",
            "description": "读取一个本地文本文件内容，并返回字符串",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "要读取的文本文件路径（绝对路径或相对路径）",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_policy_history",
            "description": "根据意图模式筛选历史仿真实验，返回策略和KPI摘要",
            "parameters": {
                "type": "object",
                "properties": {
                    "intent_pattern": {
                        "type": "string",
                        "description": "意图关键字或片段，用于匹配 intent_desc",
                    },
                    "max_records": {
                        "type": "integer",
                        "description": "返回的历史实验条数上限",
                        "default": 20,
                    },
                },
                "required": ["intent_pattern"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "save_policy_candidate",
            "description": "保存一个新的策略候选（供后续在 Matlab/RIC 中实现与验证）",
            "parameters": {
                "type": "object",
                "properties": {
                    "intent_id": {"type": "string"},
                    "proposal_json": {
                        "type": "string",
                        "description": "描述高层策略建议的JSON字符串",
                    },
                },
                "required": ["intent_id", "proposal_json"],
            },
        },
    },
]


def execute_tool(name: str, arguments: Dict[str, Any]) -> str:
    """
    统一工具执行入口，ToolRAGChatSession 会调用这里。
    """
    fn = LOCAL_TOOL_IMPLS.get(name)
    if fn is None:
        return f"[ERROR] unknown tool: {name}"

    try:
        result = fn(**arguments)
    except TypeError as e:
        return f"[ERROR] bad arguments for {name}: {e}"
    except Exception as e:
        return f"[ERROR] tool {name} failed: {e}"

    return str(result)
