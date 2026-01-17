import sys
import json

def main():
    if len(sys.argv) != 3:
        print("Usage: python nearRT_ric.py <state_in.json> <actions_out.json>")
        return

    state_file = sys.argv[1]
    action_file = sys.argv[2]

    # 读取 MATLAB 写入的近实时状态
    with open(state_file, "r") as f:
        state = json.load(f)

    num_ues = state.get("numUEs", 0)
    ue_serving = state.get("ueServingCell", [])

    # 如果长度不对，就默认所有 UE 连宏小区 1
    if not isinstance(ue_serving, list) or len(ue_serving) != num_ues:
        ue_serving = [1] * num_ues

    # 占位策略：暂时不做 traffic steering，保持原来连接不变
    actions = {
        "traffic_steering": {
            "ue_target_cell": ue_serving  # 原样返回
        }
    }

    # 写回给 MATLAB
    with open(action_file, "w") as f:
        json.dump(actions, f)

if __name__ == "__main__":
    main()
