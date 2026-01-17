# intent_agent.py
# Intent Translation Agent：自然语言意图 -> 补全后的 Intent JSON

import json
from typing import Dict, Any
from chat_session import RAGChatSession
from ollama_client import OllamaChatModel, Message
from vectorstore import SimpleVectorStore


INTENT_SYSTEM_PROMPT = """
你是 O-RAN 非实时 RIC 中的 intent translation rAPP。

【场景先验】：
- 固定场景为：1 个宏小区（cell 1）+ 2 个小小区（cell 2, 3），共 10 个物理 UE；
- 业务类型包含 Video / Gaming / Voice / URLLC，比例固定；
- 仿真时长默认约 5 秒；
- 如果意图没有特别说明作用范围，则 scope.cells 默认是 [1,2,3]，scope.duration_s 默认 5.0；
- 如果意图未指定业务类型，你需要根据描述猜测 traffic_focus：
  - 提到“视频体验”“带宽”“吞吐”等，包含 "Video"；
  - 提到“低时延”“高可靠性”等，包含 "URLLC"；
  - 如果看不出来，就写 ["ALL"]。

【你的任务】：
输入：运营人员的自然语言意图（中文或英文）。
输出：一个结构化 JSON，字段为：
{
  "intent_id": string,
  "objective": string,
  "kpi_targets": object,
  "constraints": object,
  "scope": {
    "cells": int[],
    "duration_s": number
  },
  "traffic_focus": string[]
}

说明：
- objective 例子： "maximize_sum_throughput", "improve_tail_throughput", "minimize_energy" 等；
- kpi_targets 例子： {"ue_tput_5p_min_Mbps":2.0}；
- constraints 例子： {"energy_priority":"low","coverage_priority":"medium"}；
- scope 和 traffic_focus 如果自然语言没写，你必须结合上述场景先验自动补全，不能留空或省略。

只输出一个合法 JSON，不要输出额外说明。
"""


def extract_json_block(text: str) -> str:
    """
    从模型回复中粗暴提取第一个 {...} JSON 块。
    """
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("No JSON object found in text")
    return text[start : end + 1]


def create_intent_agent(model: OllamaChatModel, retriever: SimpleVectorStore) -> RAGChatSession:
    sess = RAGChatSession(model=model, retriever=retriever, k=3)
    sess.history.append(Message(role="system", content=INTENT_SYSTEM_PROMPT))
    return sess


def translate_intent(
    intent_agent: RAGChatSession,
    operator_text: str,
    intent_id: str = "intent_001",
) -> Dict[str, Any]:
    """
    调用 Intent Agent，把运营自然语言意图转为 JSON。
    """
    user_prompt = (
        "运营意图如下：\n"
        f"{operator_text}\n\n"
        "请按 system 中的要求输出 JSON。"
    )
    reply = intent_agent.ask(user_prompt)
    raw_json = extract_json_block(reply)
    data = json.loads(raw_json)

    # 确保有 intent_id 字段
    if "intent_id" not in data or not data["intent_id"]:
        data["intent_id"] = intent_id
    return data
