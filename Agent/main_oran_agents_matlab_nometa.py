# main_oran_agents_matlab_nometa.py
# 串起来 3 个 rAPP：intent -> Matlab 仿真 -> 仿真总结 -> 策略选择
# 当前版本：不启用 meta agent，Policy 只看 intent_json + summary_text。
# 通过调用 matlab.exe -batch，而不是 matlab.engine。

from typing import Dict, Any
import os
import json
import subprocess

from ollama_client import OllamaChatModel
from vectorstore import SimpleVectorStore
from kb_loader import load_knowledge_from_folder
from intent_agent import create_intent_agent, translate_intent
from policy_agent import create_policy_agent, select_policy, DEFAULT_POLICY_LIBRARY
from sim_summary_agent import create_sim_summary_agent, summarize_simulation


# ==== 配置 ====

# LLM / 向量库
OLLAMA_BASE_URL = "http://127.0.0.1:11434"
OLLAMA_MODEL_NAME = "gpt-oss:20b"
EMBED_MODEL_NAME = "nomic-embed-text"
KNOWLEDGE_FOLDER = r"D:\agent_kb"  # 你的 RAG 知识库目录（可按需修改）

# Matlab 相关
# TODO: 把下面这个路径改成你自己电脑上的 matlab.exe
MATLAB_EXE_PATH = r"D:\matlab\bin\matlab.exe"

MATLAB_WORK_DIR = r"D:\研究生\O-RAN Simulation2\O-RAN Simulation"  # 你的 Matlab 工程目录
MATLAB_RESULT_DIR = r"D:/oran_logs/sim_results"                     # oranSim_run_two_phase_10s 输出 JSON 的目录

# 控制循环
MAX_ROUNDS = 3  # 为了速度先跑 2~3 轮就够看效果了


# ==== 工具函数 ====


def build_vector_store() -> SimpleVectorStore:
    """
    构建一个“只附加文档、不做检索”的 RAG 向量库。

    行为：
    - 从 KNOWLEDGE_FOLDER 加载所有 txt（被切 chunk）；
    - 直接保存到 vs.docs；
    - 不调用 add_documents()，因此不会对文档做 embedding；
    - similarity_search() 直接返回这些 docs。

    结果：
    - 每个 RAGChatSession 在 ask() 时，仍然会把这些文档插入到 prompt 里；
    - 完全不会访问 /api/embed，不会再有 500。
    """
    vs = SimpleVectorStore(
        embed_model=EMBED_MODEL_NAME,
        base_url=OLLAMA_BASE_URL,
    )
    docs = load_knowledge_from_folder(KNOWLEDGE_FOLDER)
    if not docs:
        print("[RAG] 提示：知识库为空，RAG 仅靠模型自身知识。")
        vs.docs = []
        vs.embeddings = []
    else:
        print(f"[RAG] 知识库已加载 {len(docs)} 个 chunks（不建向量索引，不做检索）")
        # 直接把文档塞进去，不调用 add_documents（add_documents 会触发 embedding）
        vs.docs = docs
        vs.embeddings = []

    return vs



def run_matlab_two_phase_filemode(
    round_idx: int,
    intent_desc: str,
    prev_policies: Dict[str, str],
    curr_policies: Dict[str, str],
) -> Dict[str, Any]:
    """
    不使用 matlab.engine，改成：
    1) Python 写一个 control_round_<idx>.json 到 MATLAB_RESULT_DIR；
    2) 通过 subprocess 调用 matlab.exe -batch，
       执行：cd(MATLAB_WORK_DIR); oranSim_driver_from_json(control_json_path)
    3) Matlab 在 MATLAB_RESULT_DIR 下生成 res_round_<idx>.json；
    4) Python 读回该 JSON 并返回 sim_result。
    """

    # 目录准备
    os.makedirs(MATLAB_RESULT_DIR, exist_ok=True)

    # === 1) 写控制 JSON ===
    control = {
        "round_idx": float(round_idx),  # Matlab 那边用 double
        "intent_desc": intent_desc,
        # 为了避免反斜杠转义问题，写入 JSON 的路径统一用正斜杠
        "result_dir": MATLAB_RESULT_DIR.replace("\\", "/"),
        "prev_policy": prev_policies,
        "curr_policy": curr_policies,
    }
    control_path = os.path.join(MATLAB_RESULT_DIR, f"control_round_{round_idx}.json")
    with open(control_path, "w", encoding="utf-8") as f:
        json.dump(control, f, ensure_ascii=False, indent=2)

    print(f"[Sim] 已写入控制文件: {control_path}")

    # === 2) 构造 matlab.exe -batch 命令 ===
    if not os.path.isfile(MATLAB_EXE_PATH):
        raise FileNotFoundError(f"MATLAB_EXE_PATH 不存在，请检查路径: {MATLAB_EXE_PATH}")

    matlab_work_dir_m = MATLAB_WORK_DIR.replace("\\", "/")
    control_path_m = control_path.replace("\\", "/")

    # 注意：-batch 后是一整段 Matlab 代码字符串
    # 例如：cd('D:/...'); oranSim_driver_from_json('D:/oran_logs/.../control_round_0.json');
    matlab_code = (
        f"cd('{matlab_work_dir_m}'); "
        f"oranSim_driver_from_json('{control_path_m}');"
    )

    cmd = [
        MATLAB_EXE_PATH,
        "-batch",
        matlab_code,
    ]

    print("[Sim] 启动 Matlab 进程执行仿真 ...")
    print("[Sim] 命令:", cmd)

    # === 3) 调用 Matlab，等待结束 ===
    try:
        completed = subprocess.run(
            cmd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        # 可以根据需要打印输出（太长的话可以只看前几行）
        if completed.stdout:
            print("[Matlab stdout] 前 500 字符:")
            print(completed.stdout[:500])
        if completed.stderr:
            print("[Matlab stderr] 前 500 字符:")
            print(completed.stderr[:500])
    except subprocess.CalledProcessError as e:
        print("[Sim] Matlab 进程返回非零退出码:", e.returncode)
        print("[Sim] stdout:", e.stdout[:500] if e.stdout else "")
        print("[Sim] stderr:", e.stderr[:500] if e.stderr else "")
        raise RuntimeError("Matlab 执行失败，请检查上面的 stdout/stderr 日志。") from e

    # === 4) 读取 Matlab 生成的结果 JSON ===
    res_path = os.path.join(MATLAB_RESULT_DIR, f"res_round_{round_idx}.json")
    if not os.path.isfile(res_path):
        raise FileNotFoundError(f"找不到 Matlab 生成的结果文件：{res_path}")

    print("[Sim] Matlab 仿真结果 JSON 路径：", res_path)

    with open(res_path, "r", encoding="utf-8") as f:
        sim_result = json.load(f)

    return sim_result


# ==== 主流程 ====


def main():
    # 1) 构建 LLM & 向量库
    model = OllamaChatModel(base_url=OLLAMA_BASE_URL, model_name=OLLAMA_MODEL_NAME)
    vs = build_vector_store()

    # 2) 创建各个 rAPP 的会话
    intent_agent = create_intent_agent(model, vs)
    policy_agent = create_policy_agent(model, vs)
    sim_agent = create_sim_summary_agent(model)

    # 3) 运营输入意图
    print("请输入运营层意图（中文），例如：")
    print("在保证 5% UE 吞吐不低于 2 Mbps 的前提下，尽量提高总吞吐，对能耗不太敏感。\n")
    operator_text = input("运营意图：").strip()
    if not operator_text:
        operator_text = "在保证 5% UE 吞吐不低于 2 Mbps 的前提下，尽量提高总吞吐，对能耗不太敏感。"

    # 4) Intent Agent：把自然语言意图转成 intent_json
    intent_json = translate_intent(intent_agent, operator_text, intent_id="intent_001")
    print("\n=== Intent JSON ===")
    print(intent_json)

    # 5) 初始化策略：建议和 Matlab 侧默认策略一致
    last_policy_ids: Dict[str, str] = {
        "nonRT": "nonrt_baseline",
        "nearRT": "nearrt_macro_only",
        "beam": "beam_default",
    }
    next_policy_ids: Dict[str, str] = dict(last_policy_ids)

    # 6) 多轮闭环控制
    for round_idx in range(MAX_ROUNDS):
        print(f"\n================ Round {round_idx} ================")

        if round_idx == 0:
            # 第一轮：prev 和 curr 一样，相当于“基线”场景
            prev_policies_for_sim = dict(last_policy_ids)
            curr_policies_for_sim = dict(last_policy_ids)
        else:
            # 之后各轮：上一轮 second-phase 的策略作为本轮 prev，
            # 上一轮 policy agent 选出的策略作为本轮 curr
            prev_policies_for_sim = dict(last_policy_ids)
            curr_policies_for_sim = dict(next_policy_ids)

        print("[Main] 仿真使用策略：")
        print("  prev_policies_for_sim =", prev_policies_for_sim)
        print("  curr_policies_for_sim =", curr_policies_for_sim)

        # 6.1 调 Matlab 跑 two-phase 仿真（只关心第二段的 KPI）
        sim_result = run_matlab_two_phase_filemode(
            round_idx=round_idx,
            intent_desc=operator_text,
            prev_policies=prev_policies_for_sim,
            curr_policies=curr_policies_for_sim,
        )

        print("[Main] 当前轮 sim_result.kpi =", sim_result.get("kpi", {}))

        # 6.2 把整个 sim_result 丢给 Summary Agent，让它写自然语言总结
        summary_text = summarize_simulation(sim_agent, sim_result)
        print("\n[Simulation Report 摘要]")
        print(summary_text[:500], "...\n")  # 只打印前 500 字

        # 当前轮结束后，second-phase 实际使用的策略就是 curr_policies_for_sim
        last_policy_ids = dict(curr_policies_for_sim)

        # 6.3 Policy Selection Agent：基于 intent_json + summary_text + last_policy_ids 决策下一轮策略
        policy_decision = select_policy(
            policy_agent,
            intent_json=intent_json,
            summary_text=summary_text,
            last_policy_ids=last_policy_ids,
            policy_library=DEFAULT_POLICY_LIBRARY,
        )
        print("[Main] Policy decision:", policy_decision)

        selected = policy_decision.get("selected_policies") or {}
        if not selected:
            print("[Main] Policy agent 未返回 selected_policies，下一轮沿用当前策略。")
            next_policy_ids = dict(last_policy_ids)
        else:
            next_policy_ids = {
                "nonRT": selected.get("nonRT", last_policy_ids["nonRT"]),
                "nearRT": selected.get("nearRT", last_policy_ids["nearRT"]),
                "beam": selected.get("beam", last_policy_ids["beam"]),
            }

        status = policy_decision.get("status", "ok")
        gap_summary = policy_decision.get("gap_summary", {})
        print("[Main] status =", status, ", gap_summary =", gap_summary)

        if round_idx == MAX_ROUNDS - 1:
            print("\n[Main] 已达到最大轮数，结束闭环。")

    print("\n[Main] 所有轮次结束。")


if __name__ == "__main__":
    main()
