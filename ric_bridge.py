# ric_bridge.py
# 用法：python ric_bridge.py NearRT_State.json NearRT_Actions.json
# 作用：
#   1. 从 NearRT_State.json 读取状态（MATLAB 写的）
#   2. 调用两个 Agent：TrafficSteering + CellSleeping
#   3. 把动作写入 NearRT_Actions.json，供 MATLAB 下一步读取应用

import sys
import json
from pathlib import Path
from typing import Dict, Any

from ric_agents import (
    TrafficSteeringAgent,
    CellSleepingAgent,
    traffic_steering_step,
    cell_sleeping_step,
)


def load_state(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_actions(path: Path, actions: Dict[str, Any]) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(actions, f, ensure_ascii=False, indent=2)


def main():
    if len(sys.argv) != 3:
        print("Usage: python ric_bridge.py <state_json> <actions_json>")
        sys.exit(1)

    state_path = Path(sys.argv[1])
    actions_path = Path(sys.argv[2])

    state = load_state(state_path)

    # 初始化两个 Agent（实际使用中你最好把它们持久化，避免每次重建）
    ts_agent = TrafficSteeringAgent()
    cs_agent = CellSleepingAgent()

    ts_action = traffic_steering_step(state, ts_agent)
    cs_action = cell_sleeping_step(state, cs_agent)

    # 统一打包成一个 actions 字典写回 JSON
    actions = {
        "traffic_steering": {
            # 长度 = numUEs，元素 = 0(不变) 或 1..numCells(新小区)
            "ue_target_cell": ts_action.ue_target_cell
        },
        "cell_sleeping": {
            # 长度 = numCells，元素 = true/false
            "cell_active": cs_action.cell_active
        }
    }

    save_actions(actions_path, actions)


if __name__ == "__main__":
    main()
