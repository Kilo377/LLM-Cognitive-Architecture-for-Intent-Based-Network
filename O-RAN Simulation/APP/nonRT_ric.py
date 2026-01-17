import sys
import json

def main():
    if len(sys.argv) != 3:
        print("Usage: python nonRT_ric.py <state_in.json> <actions_out.json>")
        return

    state_file = sys.argv[1]
    action_file = sys.argv[2]

    # 读取 MATLAB 写入的非实时状态
    with open(state_file, "r") as f:
        state = json.load(f)

    num_cells = state.get("numCells", 0)
    cell_active = state.get("cellActive", [])

    # 如果长度不对，就默认所有小区都开着
    if not isinstance(cell_active, list) or len(cell_active) != num_cells:
        cell_active = [True] * num_cells

    # 占位策略：不关小区，全部保持 active = True
    actions = {
        "cell_sleeping": {
            "cell_active": cell_active
        }
    }

    # 写回给 MATLAB
    with open(action_file, "w") as f:
        json.dump(actions, f)

if __name__ == "__main__":
    main()
