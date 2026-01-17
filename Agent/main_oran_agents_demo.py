# main_oran_control_demo.py
# 串起来 4 个 rAPP：intent -> 多轮 policy selection + 仿真 -> 仿真总结 -> 按需触发 meta

from typing import Dict, Any
from ollama_client import OllamaChatModel
from vectorstore import SimpleVectorStore
from kb_loader import load_knowledge_from_folder
from intent_agent import create_intent_agent, translate_intent
from policy_agent import create_policy_agent, select_policy, DEFAULT_POLICY_LIBRARY
from meta_agent import create_meta_agent, meta_optimize_intent
from sim_summary_agent import create_sim_summary_agent, summarize_simulation


# ==== 配置 ====
OLLAMA_BASE_URL = "http://127.0.0.1:11434"
OLLAMA_MODEL_NAME = "gpt-oss:20b"
EMBED_MODEL_NAME = "nomic-embed-text"
KNOWLEDGE_FOLDER = r"D:\oran_kb"  # 你的知识库目录


def build_vector_store() -> SimpleVectorStore:
    vs = SimpleVectorStore(
        embed_model=EMBED_MODEL_NAME,
        base_url=OLLAMA_BASE_URL,
    )
    docs = load_knowledge_from_folder(KNOWLEDGE_FOLDER)
    if not docs:
        print("[RAG] 提示：知识库为空，RAG 仅靠模型自身知识。")
    else:
        vs.add_documents(docs)
        print(f"[RAG] 知识库已加载 {len(docs)} 个 chunks")
    return vs


# ==== 仿真部分：目前用 stub，之后你换成 Matlab ====

def run_simulation_with_policy(
    round_idx: int,
    intent_json: Dict[str, Any],
    policy_ids: Dict[str, str],
) -> Dict[str, Any]:
    """
    这里是一个假的仿真函数：
    - 根据轮次简单构造一点“变化”的 KPI；
    - 实际工程中你应该在这里调用 Matlab，把 policy_ids 转成具体参数并跑仿真。
    返回 sim_result dict（给 summary agent 和后续使用）。
    """
    # 简单构造一个让 5% UE 吞吐逐渐上升的例子
    base_5p = 0.8 + 0.2 * round_idx
    if base_5p > 2.0:
        base_5p = 2.0

    sim_result = {
        "exp_id": f"exp_round_{round_idx}",
        "intent_desc": intent_json.get("objective", ""),
        "policy_ids": policy_ids,
        "kpi": {
            "sum_tput_Mbps": 70.0 + 5 * round_idx,
            "ue_tput_5p": base_5p,
            "ue_tput_50p": 8.0 + round_idx,
            "ue_tput_95p": 20.0,
            "estimated_energy_W": 650.0 - 10 * round_idx,
            "sleep_ratio_small_cells": 0.2 + 0.05 * round_idx,
        },
        "cells": [
            {
                "cell_id": 1,
                "role": "macro",
                "tput_Mbps": 40.0 + 2 * round_idx,
                "delay_ms": 15.0,
                "power_W": 380.0,
                "sleep_ratio": 0.0,
            },
            {
                "cell_id": 2,
                "role": "small",
                "tput_Mbps": 15.0 + round_idx,
                "delay_ms": 10.0,
                "power_W": 130.0,
                "sleep_ratio": 0.3,
            },
            {
                "cell_id": 3,
                "role": "small",
                "tput_Mbps": 15.0 + round_idx,
                "delay_ms": 9.0,
                "power_W": 120.0,
                "sleep_ratio": 0.3,
            },
        ],
        "bad_ues": [
            {
                "ue_id": 7,
                "service": "Video",
                "tput_Mbps": 0.5 + 0.1 * round_idx,
                "delay_ms": 40.0,
                "cell_history": "大部分时间由宏小区1服务，小小区2负载较低但未充分使用。",
                "position_hint": "更靠近小小区2",
            },
        ],
    }
    return sim_result


def extract_kpis_from_sim(sim_result: Dict[str, Any]) -> Dict[str, Any]:
    kpi = sim_result["kpi"]
    return {
        "ue_tput_5p": kpi.get("ue_tput_5p"),
        "sum_tput_Mbps": kpi.get("sum_tput_Mbps"),
        "energy_W": kpi.get("estimated_energy_W"),
        "sleep_ratio_small_cells": kpi.get("sleep_ratio_small_cells"),
    }


def is_gap_small_enough(gap_summary: Dict[str, Any], intent_json: Dict[str, Any]) -> bool:
    """
    一个非常粗糙的判断函数：
    - 如果 gap_summary 里有 ue_tput_5p_gap 且 >= -0.1（说明基本达标），就认为可以结束。
    实际工程中你可以更细致地解析 gap_summary。
    """
    gap = gap_summary.get("ue_tput_5p_gap")
    if isinstance(gap, (int, float)) and gap >= -0.1:
        return True
    return False


def main():
    # 1) 初始化模型和向量库
    model = OllamaChatModel(
        model_name=OLLAMA_MODEL_NAME,
        base_url=OLLAMA_BASE_URL,
    )
    vs = build_vector_store()

    # 2) 创建四个 rAPP agent
    intent_agent = create_intent_agent(model, vs)
    policy_agent = create_policy_agent(model, vs)
    meta_agent = create_meta_agent(model, vs)
    sim_agent = create_sim_summary_agent(model)

    # 3) 输入一个运营层自然语言意图
    print("请输入运营层意图（中文），例如：")
    print("在保证 5% UE 吞吐不低于 2 Mbps 的前提下，尽量提高总吞吐，对能耗不太敏感。\n")
    operator_text = input("运营意图：").strip()
    if not operator_text:
        operator_text = "在保证 5% UE 吞吐不低于 2 Mbps 的前提下，尽量提高总吞吐，对能耗不太敏感。"

    # 4) Intent Translation（只做一次）
    intent_json = translate_intent(intent_agent, operator_text, intent_id="intent_001")
    print("\n=== Intent JSON ===")
    print(intent_json)

    # 5) 初始策略 id（也可以从策略库里选一个默认）
    last_policy_ids = {
        "nonRT": DEFAULT_POLICY_LIBRARY["nonRT"][0]["id"],
        "nearRT": DEFAULT_POLICY_LIBRARY["nearRT"][0]["id"],
        "beam": DEFAULT_POLICY_LIBRARY["beam"][0]["id"],
    }

    # 6) 多轮控制循环
    max_rounds = 5
    for round_idx in range(max_rounds):
        print(f"\n================ Round {round_idx} ================")
        print("[Main] 当前策略组合：", last_policy_ids)

        # 6.1 用当前策略组合跑一轮仿真（这里用 stub）
        sim_result = run_simulation_with_policy(round_idx, intent_json, last_policy_ids)
        current_kpis = extract_kpis_from_sim(sim_result)
        print("[Main] 当前KPI：", current_kpis)

        # 6.2 仿真总结（可选，每轮或每几轮调用一次）
        report_text = summarize_simulation(sim_agent, sim_result)
        print("\n[Simulation Report 摘要]")
        print(report_text[:500], "...\n")  # 只打印前 500 字，避免太长

        # 6.3 Policy Selection Agent：评估 gap + 选择下一轮策略 / 决定是否需要 meta
        policy_decision = select_policy(
            policy_agent,
            intent_json=intent_json,
            current_kpis=current_kpis,
            last_policy_ids=last_policy_ids,
            policy_library=DEFAULT_POLICY_LIBRARY,
        )
        print("[Main] Policy decision:", policy_decision)

        # 更新下一轮策略
        last_policy_ids = policy_decision["selected_policies"]

        # 6.4 判断是否需要调用 Meta Agent
        if policy_decision.get("status") == "need_meta":
            print("\n>>> 触发元认知 rAPP（Meta Agent），请求高层策略优化建议...")
            meta_reply = meta_optimize_intent(
                meta_agent,
                intent_json=intent_json,
                policy_decision=policy_decision,
            )
            print("\n[Meta-cognitive 分析与策略优化建议]")
            print(meta_reply)
            # 通常这里不会立刻生效，而是你读完建议后，拿它去问 GPT-5.1 改代码/策略库

        # 6.5 如果 gap 已经足够小，可以提前停止迭代
        gap_summary = policy_decision.get("gap_summary", {})
        if is_gap_small_enough(gap_summary, intent_json):
            print("\n[Main] 意图指标已基本达标，停止迭代。")
            break


if __name__ == "__main__":
    main()
