function oranSim_driver_from_json(controlPath)
% oranSim_driver_from_json
% 从 JSON 控制文件中读取参数，调用 oranSim_run_two_phase_10s，
% 生成 res_round_<idx>.json，供 Python 使用。
%
% 用法（由 Python 调用 matlab.exe -batch）：
%   matlab -batch "cd('D:/.../O-RAN Simulation'); oranSim_driver_from_json('D:/oran_logs/sim_results/control_round_0.json');"

    if nargin < 1 || isempty(controlPath)
        error("必须提供 controlPath 参数（JSON 控制文件路径）。");
    end

    fprintf("【Matlab】读取控制文件: %s\n", controlPath);

    % === 1) 读 JSON 控制文件 ===
    fid = fopen(controlPath, "r");
    if fid == -1
        error("无法打开控制文件: %s", controlPath);
    end
    raw = fread(fid, Inf, "*char")';
    fclose(fid);

    ctrl = jsondecode(raw);

    % 必要字段
    if ~isfield(ctrl, "round_idx") || ~isfield(ctrl, "intent_desc") || ...
       ~isfield(ctrl, "result_dir") || ~isfield(ctrl, "prev_policy") || ...
       ~isfield(ctrl, "curr_policy")
        error("控制 JSON 缺少必要字段（round_idx / intent_desc / result_dir / prev_policy / curr_policy）");
    end

    roundIdx   = ctrl.round_idx;
    intentDesc = ctrl.intent_desc;
    resultDir  = ctrl.result_dir;
    prevPolicy = ctrl.prev_policy;
    currPolicy = ctrl.curr_policy;

    % === 2) 调用你之前写好的 two-phase 仿真封装 ===
    % 这里会在 resultDir 下生成 res_round_<roundIdx>.json
    resPath = oranSim_run_two_phase_10s(roundIdx, prevPolicy, currPolicy, intentDesc, resultDir);

    % 打印一下给日志看
    fprintf("【Matlab】本轮仿真结果已写入: %s\n", resPath);
end
