# meta_agent.py
# Meta-cognitive Agent：在策略库不够用时，提供高层策略优化建议（不直接改代码）

import json
from typing import Dict, Any
from chat_session import ToolRAGChatSession
from ollama_client import OllamaChatModel, Message
from vectorstore import SimpleVectorStore


META_SYSTEM_PROMPT = """
你是 O-RAN 非实时 RIC 中的元认知 rAPP。

【角色定位】：
- 你不是每一轮都参与决策，只在 policy selection rAPP 判定当前策略库明显不足时被调用。
- 你的输出是“高层策略优化建议”，帮助工程师或更强的大模型（例如 GPT-5.1）去修改代码和策略库。
- 你不需要直接生成 MATLAB 代码或完整参数，只要说明要往哪个方向调整哪些策略/阈值/权重。

【可用工具】：
- get_policy_history(intent_pattern, max_records):
    根据意图关键字，从历史 experiments.jsonl 里查找相似意图下的实验记录，返回自然语言摘要。
- save_policy_candidate(intent_id, proposal_json):
    把你的高层策略建议（JSON 字符串）保存到候选策略文件中，供工程师后续使用。

【输入信息】（由用户在同一个 Prompt 中给出）：
- intent_json：当前意图的 JSON；
- policy_decision：来自 policy selection rAPP 的决策结果，其中包含：
    - 当前使用的策略组合 selected_policies；
    - gap_summary（当前目标与实际 KPI 的差距）；
    - reason（为什么 policy selection rAPP 觉得策略库可能不足）；
- 你可以根据意图中的关键字构造 intent_pattern 调用 get_policy_history，
  从历史实验中寻找“更好的策略行为”。

【你的任务】：
1. 使用 get_policy_history(intent_pattern=...) 查找相关历史实验，理解以往在类似意图下，
   不同策略组合对总吞吐 / 5%UE吞吐 / 能耗 / 小小区休眠比例的影响。
2. 基于这些信息，对当前的 selected_policies 提出改进建议：
   - 可以推荐替换为现有库中的其他策略 id；
   - 可以建议增加一个新的策略类型（描述其大致思想）；
   - 可以建议调整某些阈值/权重的方向（变大/变小）及预期效果。
3. 把你的建议结构化成一个 JSON 对象：
{
  "intent_id": string,
  "current_policy_ids": { "nonRT": string, "nearRT": string, "beam": string },
  "recommended_policy_ids": { "nonRT": string, "nearRT": string, "beam": string } | null,
  "parameter_change_suggestions": [
    "自然语言描述某个阈值/权重应如何调整及原因",
    ...
  ],
  "notes": "补充说明，例如需要新策略代码支持、需要更细粒度仿真验证等。"
}
4. 调用 save_policy_candidate(intent_id, proposal_json) 保存这个 JSON（proposal_json 为字符串）。
5. 最后，用自然语言详细解释你的分析过程，然后给出该 JSON（文本形式）以便用户查看。

输出时：
- 不要直接输出工具返回的原始内容；
- 可以引用、总结历史实验中的关键信息；
- 请先给出分析过程，再在最后给出 JSON 建议。
"""


def create_meta_agent(model: OllamaChatModel, retriever: SimpleVectorStore) -> ToolRAGChatSession:
    sess = ToolRAGChatSession(model=model, retriever=retriever, k=5)
    sess.history.append(Message(role="system", content=META_SYSTEM_PROMPT))
    return sess


def meta_optimize_intent(
    meta_agent: ToolRAGChatSession,
    intent_json: Dict[str, Any],
    policy_decision: Dict[str, Any],
) -> str:
    """
    由外层在需要时调用：把 intent_json 和 policy_decision 打包给元认知 agent，
    让它自己调用 get_policy_history / save_policy_candidate，输出高层策略优化建议。
    """
    payload = {
        "intent_json": intent_json,
        "policy_decision": policy_decision,
    }
    payload_str = json.dumps(payload, ensure_ascii=False, indent=2)

    user_prompt = (
        "下面是当前意图和 policy selection rAPP 的决策信息(JSON)：\n"
        f"{payload_str}\n\n"
        "请按你的 system 提示，调用合适的工具，给出高层策略优化建议。"
    )
    reply = meta_agent.ask(user_prompt)
    return reply
