# policy_agent.py
# Policy Selection Agent：Intent JSON + 上一轮仿真总结 -> 策略库中选择 + 是否需要 meta（目前不启用 meta）

import json
from typing import Dict, Any
from chat_session import RAGChatSession
from ollama_client import OllamaChatModel, Message
from vectorstore import SimpleVectorStore
from intent_agent import extract_json_block


# ==== 策略库：要和 Matlab 侧 setupRicPoliciesTwoPhase 里的 ID 对齐 ====

DEFAULT_POLICY_LIBRARY: Dict[str, Any] = {
    "nonRT": [
        {
            "id": "nonrt_baseline",
            "desc": "基线：所有小区保持开启，不做激进睡眠，保证覆盖与稳定性。"
        },
        {
            "id": "nonrt_throughput_v1",
            "desc": "偏向打开更多小小区，降低宏小区负载，以提高总吞吐，能耗较高。"
        },
        {
            "id": "nonrt_energy_simple",
            "desc": "简单节能：低负载时让小小区更容易进入 sleep 状态，优先降低能耗。"
        },
        {
            "id": "nonrt_balanced_v1",
            "desc": "折中策略：根据负载适度开启 / 休眠小小区，在吞吐与能耗之间平衡。"
        },
    ],
    "nearRT": [
        {
            "id": "nearrt_macro_only",
            "desc": "宏小区优先：大部分 UE 挂宏小区，只在极端情况下 offload 到小小区。"
        },
        {
            "id": "nearrt_throughput_v1",
            "desc": "偏吞吐：更积极地将 Video/URLLC 等高带宽 UE offload 到空闲小小区。"
        },
        {
            "id": "nearrt_tail_aware_v1",
            "desc": "尾部友好：更照顾 5% 低吞吐 UE，对高负载小区的 offload 更保守。"
        },
        {
            "id": "nearrt_smallcell_bias",
            "desc": "小小区偏置：在保证覆盖的前提下，更鼓励 UE 连接到小小区以缓解宏小区压力。"
        },
    ],
    "beam": [
        {
            "id": "beam_default",
            "desc": "使用系统默认波束（不强制特定码本策略）。"
        },
        {
            "id": "beam_round_robin",
            "desc": "简单轮询码本波束，保证波束资源得到均匀探索。"
        },
        {
            "id": "beam_geometry_8",
            "desc": "几何最近波束，8 条波束（粗粒度）。"
        },
        {
            "id": "beam_geometry_16",
            "desc": "几何最近波束，16 条波束（更精细）。"
        },
    ],
}


POLICY_SYSTEM_PROMPT = """
你是 O-RAN 非实时 RIC 中的 policy selection rAPP。

【场景】：
- 1 个宏小区 + 2 个小小区，10 个物理 UE，业务为 Video / Gaming / Voice / URLLC。
- non-RT / near-RT / Beam 三层都只能从给定策略库中选择策略 id，不允许凭空创造新策略代码。

【策略库】：
用户会以 JSON 的形式给你策略库（nonRT / nearRT / beam），每个策略有 id 和 desc。

【输入】（都在同一个 JSON 里提供）：
- intent_json：包含 objective / kpi_targets / constraints / traffic_focus 等；
- summary_text：上一轮由 simulation summary rAPP 生成的自然语言实验报告，其中已经描述了本轮仿真的 KPI、问题小区 / UE 等信息；
- last_policy_ids：上一轮实际使用的策略组合（nonRT / nearRT / beam 的策略 id），对应本轮 summary_text 中的结果；
- policy_library：策略库 JSON（nonRT / nearRT / beam 三类）。

【你的任务】：
1. 仔细阅读 summary_text，从中尽量提取关键 KPI 信息：
   - 总吞吐（sum throughput）
   - 5% UE 吞吐（ue_tput_5p）
   - 能耗 / 小小区 sleep 比例等
   不需要精确数字，可以用“明显低于目标 / 大致接近目标 / 远高于目标”等定性描述。
2. 将这些“当前表现”与 intent_json.kpi_targets 和 constraints（例如 energy_priority）进行比较，
   总结出一个 gap_summary（你可以自由设计字段，只要能清楚表达“目标 vs 当前”的差距）。
3. 在策略库中选择下一轮要使用的策略组合 selected_policies（nonRT / nearRT / beam 的 id）：
   - 合理利用 last_policy_ids：如果当前策略看起来不错，可以保留其中一部分；
   - 如果 5% UE 吞吐偏低，可以偏向 tail-aware 或 smallcell-bias 类策略；
   - 如果能耗过高，可以偏向 energy_simple / baseline 等更节能的策略。
4. 如果你认为通过在策略库中调参/切换策略仍然有希望逐步缩小 gap，则设置 status="ok"。
5. 如果你认为当前策略库明显不足（例如多项 KPI 严重偏离目标，且现有策略都无法兼顾），
   则设置 status="need_meta"，并在 reason 中说明为什么需要调用元认知 rAPP 帮忙设计新策略
   （虽然当前 demo 不真正调用 meta，但你仍需正确给出判断）。

【输出 JSON 格式】：
严格输出一个 JSON 对象，例如：
{
  "intent_id": "intent_001",
  "selected_policies": {
    "nonRT": "nonrt_balanced_v1",
    "nearRT": "nearrt_tail_aware_v1",
    "beam": "beam_round_robin"
  },
  "status": "ok",
  "gap_summary": {
    "ue_tput_5p_target": 2.0,
    "ue_tput_5p_trend": "明显低于目标",
    "sum_tput_trend": "略有提升",
    "energy_trend": "能耗略高，但在意图允许范围内"
  },
  "reason": "简要说明：为什么这样选策略，以及对 gap 的整体判断。"
}

不要输出任何额外说明，只输出一个 JSON 对象。
"""


def create_policy_agent(model: OllamaChatModel, retriever: SimpleVectorStore) -> RAGChatSession:
    """
    创建带 RAG 的 Policy Agent 会话，并注入 system prompt。
    """
    sess = RAGChatSession(model=model, retriever=retriever, k=3)
    sess.history.append(Message(role="system", content=POLICY_SYSTEM_PROMPT))
    return sess


def select_policy(
    policy_agent: RAGChatSession,
    intent_json: Dict[str, Any],
    summary_text: str,
    last_policy_ids: Dict[str, str],
    policy_library: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    """
    调用 Policy Agent：根据意图 + 上一轮 summary 文本 + 上一轮策略组合，
    从策略库中选择下一轮策略组合，并给出 gap_summary / status / reason。

    注意：这里不再显式传入结构化 KPI，而是完全依赖 summary_text 中的描述。
    """
    if policy_library is None:
        policy_library = DEFAULT_POLICY_LIBRARY

    payload = {
        "intent_json": intent_json,
        "summary_text": summary_text,
        "last_policy_ids": last_policy_ids,
        "policy_library": policy_library,
    }
    payload_str = json.dumps(payload, ensure_ascii=False, indent=2)

    user_prompt = (
        "下面是本轮策略决策所需的全部输入(JSON)：\n"
        f"{payload_str}\n\n"
        "请按照 system 提示，只输出一个 JSON 对象。"
    )

    reply = policy_agent.ask(user_prompt)
    raw_json = extract_json_block(reply)
    data = json.loads(raw_json)

    # 补上 intent_id，方便后续 trace
    if "intent_id" not in data or not data.get("intent_id"):
        data["intent_id"] = intent_json.get("intent_id", "intent_001")

    return data
