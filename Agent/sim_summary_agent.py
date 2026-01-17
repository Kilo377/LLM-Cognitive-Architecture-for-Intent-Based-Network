# sim_summary_agent.py
# Simulation Summary Agent：结构化仿真结果 -> 自然语言实验报告

import json
from typing import Dict, Any
from chat_session import ChatSession
from ollama_client import OllamaChatModel, Message


SIM_SUMMARY_SYSTEM_PROMPT = """
你是 O-RAN 仿真平台中的 simulation summary rAPP。
你的任务是：根据给定的一次实验配置和 KPI，生成一份标准化的自然语言实验报告。

报告格式严格如下：
===== Experiment <exp_id> =====
Intent: <意图自然语言>

[场景总结]
... 3-6 行，描述拓扑、UE 数量、业务类型分布、仿真时长等 ...

[控制策略总结]
[non-RT RIC: Cell Sleeping]
... 总结 non-RT 策略（包括使用的策略 id 和整体倾向） ...
[near-RT RIC: Traffic Steering]
... 总结 near-RT 策略 ...
[Beam RIC: Beamforming]
... 总结 Beam 策略 ...

[KPI 总体]
... 总吞吐、UE 吞吐分布、总体能耗等 ...

[小区级 KPI]
- 小区 1: ...
- 小区 2: ...
- 小区 3: ...

[问题 UE（表现较差的 UE 提示）]
- UE x: ... 问题 + 可能原因 + 改进建议 ...
(列出若干典型表现较差的 UE)

===== End of Experiment <exp_id> =====

输入 JSON 包含：
- exp_id, intent_desc
- policy_ids: {nonRT, nearRT, beam}
- kpi: sum_tput_Mbps, ue_tput_5p/50p/95p, estimated_energy_W, sleep_ratio_small_cells
- cells: 每个小区的吞吐/时延/功率/sleep 比例
- bad_ues: 若干表现较差的 UE 的结构化信息（id, service, 吞吐, 时延, 历史提示等）

请仔细阅读 JSON，按照上面的格式输出一份完整报告。
不要输出 JSON，只输出自然语言报告。
"""


def create_sim_summary_agent(model: OllamaChatModel) -> ChatSession:
    sess = ChatSession(model=model)
    sess.history.append(Message(role="system", content=SIM_SUMMARY_SYSTEM_PROMPT))
    return sess


def summarize_simulation(sim_agent: ChatSession, sim_result: Dict[str, Any]) -> str:
    """
    sim_result: 一次仿真的结构化结果 dict（由 Matlab 或 Python 构造）
    """
    sim_str = json.dumps(sim_result, ensure_ascii=False, indent=2)
    user_prompt = (
        "下面是本次实验的结构化结果(JSON)：\n"
        f"{sim_str}\n\n"
        "请根据 system 提示，生成一份完整的实验报告。"
    )
    reply = sim_agent.ask(user_prompt)
    return reply
