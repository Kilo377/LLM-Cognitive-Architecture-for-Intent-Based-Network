function oranSim_RL_step
% oranSim_RL_step.m
% 使用 oranScenarioInit() 搭建好场景之后：
%   - 定义两个时间尺度：
%       near-RT:  Traffic Steering (App1)，每 50ms 调用一次 Python
%       non-RT:   Cell Sleeping    (App2)，每 1s 调用一次 Python
%   - 通过 JSON 文件与 Python 脚本交互：
%       nearRT_ric.py NearRT_State.json NearRT_Actions.json
%       nonRT_ric.py  NonRT_State.json  NonRT_Actions.json

%% 1) 初始化场景（这部分逻辑都在 oranScenarioInit.m，不用动）
env = oranScenarioInit();

networkSimulator   = env.networkSimulator;
simulationTime     = env.simulationTime;
gNBs               = env.gNBs;
allUEs             = env.allUEs;
ueServingCell      = env.ueServingCell;
cellActive         = env.cellActive;
appType            = env.appType;
metricsVisualizer  = env.metricsVisualizer;

%% 2) RIC 时间尺度参数（你以后可以在这里改）
nearRTStep    = 0.05;   % 近实时 RIC 周期：Traffic Steering（50 ms 一次）
nonRTPeriod   = 1.0;    % 非实时 RIC 周期：Cell Sleeping（1 s 一次）
nextNonRTTime = 0.0;    % 下一次 Cell Sleeping 决策时间点

%% 3) 双时间尺度 step-by-step 仿真

fprintf("开始 step-by-step 仿真，总时长 %.2f 秒...\n", simulationTime);

currentTime = 0.0;

while currentTime < simulationTime

    % ---------- 1) 非实时 RIC：Cell Sleeping（每 nonRTPeriod 才触发一次） ----------
    if currentTime >= nextNonRTTime
        nonRTState = collectNonRTState(gNBs, ueServingCell, cellActive, appType);
        saveJSON("NonRT_State.json", nonRTState);

        % 调 Python non-RT RIC
        cmdNonRT = 'python nonRT_ric.py NonRT_State.json NonRT_Actions.json';
        statusNonRT = system(cmdNonRT);
        if statusNonRT ~= 0
            warning("non-RT RIC (Cell Sleeping) Python 调用失败，保持上一次 cellActive 不变。");
        else
            actionsNonRT = loadJSON("NonRT_Actions.json", struct());
            cellActive   = applyCellSleepingFromPython(actionsNonRT, cellActive);
        end

        nextNonRTTime = nextNonRTTime + nonRTPeriod;
    end

    % ---------- 2) 近实时 RIC：Traffic Steering（每个 nearRTStep 都调用） ----------
    nearRTState = collectNearRTState(gNBs, ueServingCell, cellActive, appType);
    saveJSON("NearRT_State.json", nearRTState);

    cmdNearRT    = 'python nearRT_ric.py NearRT_State.json NearRT_Actions.json';
    statusNearRT = system(cmdNearRT);
    if statusNearRT ~= 0
        warning("near-RT RIC (Traffic Steering) Python 调用失败，保持上一次 ueServingCell 不变。");
    else
        actionsNearRT = loadJSON("NearRT_Actions.json", struct());
        ueServingCell = applyTrafficSteeringFromPython(actionsNearRT, ueServingCell, cellActive);
    end

    % 当前版本：
    %   - 只是更新了 ueServingCell 的"逻辑归属"，并没有真正执行 HO / 断开/重连
    %   - cellActive 目前是逻辑标志（你后续可以用它屏蔽某些小区的调度）

    % ---------- 3) 环境往前走一个 nearRTStep ----------
    tEnd = min(currentTime + nearRTStep, simulationTime);
    run(networkSimulator, tEnd);
    currentTime = tEnd;
end

fprintf("仿真结束。\n");

%% 4) KPI 输出（简单版）
gNBStats = statistics(gNBs);          %#ok<NASGU>
ueStats  = statistics(allUEs);        %#ok<NASGU>
displayPerformanceIndicators(metricsVisualizer);

end  % function oranSim_RL_step


%% ===== 本文件内部：状态收集 & JSON & 动作应用 =====

function nearState = collectNearRTState(gNBs, ueServingCell, cellActive, appType)
% 近实时 RIC 使用的状态（Traffic Steering）
numCells = numel(gNBs);
numUEs   = numel(ueServingCell);

nearState = struct();
nearState.numCells      = numCells;
nearState.numUEs        = numUEs;
nearState.ueServingCell = ueServingCell(:)';     % 行向量
nearState.cellActive    = logical(cellActive(:))';
nearState.trafficType   = appType(:)';           % 1..4

% TODO：将来这里可以加瞬时负载、瞬时队列长度、SINR、吞吐等
end

function nonRTState = collectNonRTState(gNBs, ueServingCell, cellActive, appType)
% 非实时 RIC 使用的状态（Cell Sleeping）
% 当前先复用与 nearRT 相同的字段，将来你可以改成"慢变量"（平均负载等）
nonRTState = collectNearRTState(gNBs, ueServingCell, cellActive, appType);
end

function saveJSON(filename, data)
jsonStr = jsonencode(data);
fid = fopen(filename,'w');
if fid == -1
    error("无法创建 JSON 文件: %s", filename);
end
fwrite(fid, jsonStr, 'char');
fclose(fid);
end

function data = loadJSON(filename, defaultVal)
if ~isfile(filename)
    data = defaultVal;
    return;
end
fid = fopen(filename,'r');
raw = fread(fid, inf, '*char')';
fclose(fid);
if isempty(raw)
    data = defaultVal;
else
    data = jsondecode(raw);
end
end

function ueServingCell = applyTrafficSteeringFromPython(actions, ueServingCell, cellActive)
% 从 nearRT_ric.py 的动作中读取 Traffic Steering 决策
numCells = numel(cellActive);
numUEs   = numel(ueServingCell);

new_ueServingCell = ueServingCell;

if isfield(actions, 'traffic_steering')
    ts = actions.traffic_steering;
    if isfield(ts, 'ue_target_cell')
        target = ts.ue_target_cell;
        if numel(target) == numUEs
            target = target(:);
            for ueIdx = 1:numUEs
                tgt = target(ueIdx);
                if tgt > 0 && tgt <= numCells
                    % 如果目标小区被 Cell Sleeping 关掉，可以选择忽略
                    if cellActive(tgt)
                        new_ueServingCell(ueIdx) = tgt;
                    end
                end
            end
        end
    end
end

ueServingCell = new_ueServingCell;
end

function cellActive = applyCellSleepingFromPython(actions, cellActive)
% 从 nonRT_ric.py 的动作中读取 Cell Sleeping 决策
numCells = numel(cellActive);
new_cellActive = cellActive;

if isfield(actions, 'cell_sleeping')
    cs = actions.cell_sleeping;
    if isfield(cs, 'cell_active')
        act = logical(cs.cell_active);
        if numel(act) == numCells
            new_cellActive = act(:);
        end
    end
end

cellActive = new_cellActive;
end
