function oranSim_RL_step_light
% oranSim_RL_step_light.m  (LIGHT VERSION + 双 UE + DataRate 切换)
%
% - 使用 oranScenarioInit_light() 搭好场景
% - 支持：
%   * near-RT RIC:  Traffic Steering (App1)，每 50 ms
%   * non-RT RIC:   Cell Sleeping    (App2)，每 1  s
% - 实现：只改 DataRate，不改 GeneratePacket
%
% 重要：本版本使用 wirelessNetworkSimulator.scheduleAction
%       在仿真过程中周期性调用 RIC（run 只调用一次！）
%       RIC 完全用 MATLAB 实现（nearRT_ric.m, nonRT_ric.m）。

%% ===== 全局变量，用于 RIC 回调在不同时间共享状态 =====
global RIC_gNBs RIC_allUEs
global RIC_ueServingCell RIC_ueSmallCell RIC_cellActive RIC_appType
global RIC_dlTrafficMacro RIC_dlTrafficSmall
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate RIC_lowRate

%% 0) 是否启用 RIC（true=启用 MATLAB RIC，false=跑 baseline）
useRIC = true;  % 如果想跑 baseline，把这里改成 false

%% 1) 初始化场景（单独的文件：oranScenarioInit_light.m）
env = oranScenarioInit_light();

networkSimulator   = env.networkSimulator;
simulationTimeEnv  = env.simulationTime;   % 仿真器上限（例如 5 s）
targetSimTime      = 1.0;                 % 真正想跑的时长（1 s）

gNBs               = env.gNBs;
allUEs             = env.allUEs;

numUEsPhysical     = env.numUEsPhysical;
macroUEIndices     = env.macroUEIndices;
smallUEIndices     = env.smallUEIndices;
ueSmallCell        = env.ueSmallCell;

ueServingCell      = env.ueServingCell;   % 1 = 宏, 2..numCells = 微（当前全 1）
cellActive         = env.cellActive;
appType            = env.appType;

dlTrafficMacro     = env.dlTrafficMacro;
dlTrafficSmall     = env.dlTrafficSmall;

videoDataRateKbps  = env.videoDataRateKbps;
gamingDataRateKbps = env.gamingDataRateKbps;
voiceDataRateKbps  = env.voiceDataRateKbps;
urllcDataRateKbps  = env.urllcDataRateKbps;
lowDataRateKbps    = env.lowDataRateKbps;

numCells = numel(gNBs);

% 把需要在回调里用到的东西存进全局
RIC_gNBs           = gNBs;
RIC_allUEs         = allUEs;
RIC_ueServingCell  = ueServingCell;
RIC_ueSmallCell    = ueSmallCell;
RIC_cellActive     = cellActive;
RIC_appType        = appType;

RIC_dlTrafficMacro = dlTrafficMacro;
RIC_dlTrafficSmall = dlTrafficSmall;

RIC_videoRate      = videoDataRateKbps;
RIC_gamingRate     = gamingDataRateKbps;
RIC_voiceRate      = voiceDataRateKbps;
RIC_urllcRate      = urllcDataRateKbps;
RIC_lowRate        = lowDataRateKbps;

%% 2) baseline：不开 RIC
if ~useRIC
    fprintf("开始 LIGHT baseline 仿真（不调用 RIC），总时长 %.2f 秒...\n", targetSimTime);
    run(networkSimulator, targetSimTime);   % run 只调用一次
    fprintf("仿真结束。\n");
    actualSimTime = targetSimTime;

else
    %% 3) 启用 MATLAB RIC：用 scheduleAction 定期调用 RIC 回调（run 只调一次）

    nearRTStep    = 0.05;   % 50 ms
    nonRTPeriod   = 1.0;    % 1  s

    if targetSimTime > simulationTimeEnv
        warning("targetSimTime=%.2f 超过仿真器上限 %.2f，自动截断到上限。", ...
            targetSimTime, simulationTimeEnv);
        targetSimTime = simulationTimeEnv;
    end

    fprintf("开始 LIGHT step-by-step 仿真（启用 MATLAB RIC），目标时长 %.2f 秒（仿真器上限 %.2f 秒）...\n", ...
        targetSimTime, simulationTimeEnv);

    userdataNear  = struct("Simulator", networkSimulator);
    userdataNonRT = struct("Simulator", networkSimulator);

    % 周期调用 near-RT RIC（Traffic Steering）
    scheduleAction(networkSimulator, @nearRTCallback, userdataNear,  0, nearRTStep);

    % 周期调用 non-RT RIC（Cell Sleeping）
    scheduleAction(networkSimulator, @nonRTCallback,  userdataNonRT, 0, nonRTPeriod);

    % 仿真一次性跑完 targetSimTime，期间 scheduleAction 会触发回调
    run(networkSimulator, targetSimTime);

    fprintf("仿真结束。\n");
    actualSimTime = targetSimTime;
end

%% 4) KPI：吞吐统计（轻量输出）

gNBStats = statistics(gNBs);
ueStats  = statistics(allUEs);

[cellTputMbps, totalTputMbps] = extractCellThroughput(gNBStats, actualSimTime);
ueTputLegMbps = extractUEThroughput(ueStats, actualSimTime);   % 对应 allUEs，每个物理 UE 两条 leg

fprintf("\n===== LIGHT MODE KPI 输出 =====\n");

% 4.1 每小区吞吐
if ~isempty(cellTputMbps) && any(~isnan(cellTputMbps))
    for c = 1:numCells
        if ~isnan(cellTputMbps(c))
            fprintf("  小区 %d 下行吞吐 ≈ %.2f Mbps\n", c, cellTputMbps(c));
        else
            fprintf("  小区 %d 下行吞吐：无法解析（请检查 gNBStats(%d) 结构）\n", c, c);
        end
    end
    if ~isnan(totalTputMbps)
        fprintf("  => 总下行吞吐 ≈ %.2f Mbps\n", totalTputMbps);
    end
else
    fprintf("  [提示] 无法从 gNBStats 中自动解析吞吐字段，请在 MATLAB 中查看 gNBStats 结构。\n");
end

% 4.2 物理 UE 吞吐分布（宏 leg + 微 leg 合并）
if ~isempty(ueTputLegMbps) && any(~isnan(ueTputLegMbps))
    ueTputPhys = nan(numUEsPhysical,1);
    for p = 1:numUEsPhysical
        idxM = macroUEIndices(p);
        idxS = smallUEIndices(p);
        vM = ueTputLegMbps(idxM);
        vS = ueTputLegMbps(idxS);
        if isnan(vM), vM = 0; end
        if isnan(vS), vS = 0; end
        ueTputPhys(p) = vM + vS;
    end

    pTiles = [5 50 95];
    q = myQuantile(ueTputPhys, pTiles);
    fprintf("  物理 UE 吞吐分布 (Mbps): 5%%=%.2f, 50%%=%.2f, 95%%=%.2f\n", q(1), q(2), q(3));
else
    fprintf("  [提示] 无法从 ueStats 中自动解析吞吐字段，请在 MATLAB 中查看 ueStats 结构。\n");
end

fprintf("===== 结束 =====\n");

end  % function oranSim_RL_step_light

%% ====== RIC 回调函数（通过 scheduleAction 调用） ======

function nearRTCallback(actionID, userdata) %#ok<INUSD>
% 每 50 ms 调一次：Traffic Steering（MATLAB 实现）

global RIC_gNBs
global RIC_ueServingCell RIC_ueSmallCell RIC_cellActive RIC_appType
global RIC_dlTrafficMacro RIC_dlTrafficSmall
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate RIC_lowRate

sim = userdata.Simulator;
currentTime = sim.CurrentTime;

try
    % 1) 组装 state 结构（字段与 Python nearRT_ric.py 一致）
    state = collectNearRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 2) 调用独立文件 nearRT_ric.m
    [useSmall, reward] = nearRT_ric(state);

    % 3) 构造 actions 结构，并应用（DataRate 切换 + ueServingCell 更新）
    actionsNearRT = struct();
    actionsNearRT.traffic_steering = struct("use_small", useSmall);

    RIC_ueServingCell = applyTrafficSteeringFromPython( ...
        actionsNearRT, RIC_ueServingCell, RIC_ueSmallCell, RIC_cellActive, ...
        RIC_dlTrafficMacro, RIC_dlTrafficSmall, RIC_appType, ...
        RIC_videoRate, RIC_gamingRate, RIC_voiceRate, RIC_urllcRate, RIC_lowRate);

    % 4) 记录 log（jsonl）
    logEntry = struct();
    logEntry.state  = state;
    logEntry.action = actionsNearRT.traffic_steering;
    logEntry.reward = reward;
    appendJSONL("nearRT_log.jsonl", logEntry);

catch ME
    warning("[near-RT] t=%.3f s: 回调异常：%s", currentTime, ME.message);
end
end

function nonRTCallback(actionID, userdata) %#ok<INUSD>
% 每 1 s 调一次：Cell Sleeping（MATLAB 实现）

global RIC_gNBs
global RIC_ueServingCell RIC_ueSmallCell RIC_cellActive RIC_appType
global RIC_dlTrafficMacro RIC_dlTrafficSmall
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate RIC_lowRate

sim = userdata.Simulator;
currentTime = sim.CurrentTime;

try
    % 1) 组装 state 结构（字段与 Python nonRT_ric.py 一致）
    state = collectNonRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 2) 调用独立文件 nonRT_ric.m
    [cellActiveAction, reward] = nonRT_ric(state);

    % 3) 构造 actions 结构，并应用（cellActive 更新 + UE 回落宏 + DataRate 调整）
    actionsNonRT = struct();
    actionsNonRT.cell_sleeping = struct("cell_active", cellActiveAction);

    [RIC_cellActive, RIC_ueServingCell] = applyCellSleepingFromPython( ...
        actionsNonRT, RIC_cellActive, RIC_ueSmallCell, RIC_ueServingCell, ...
        RIC_dlTrafficMacro, RIC_dlTrafficSmall, RIC_appType, ...
        RIC_videoRate, RIC_gamingRate, RIC_voiceRate, RIC_urllcRate, RIC_lowRate);

    % 4) 记录 log
    logEntry = struct();
    logEntry.state  = state;
    logEntry.action = actionsNonRT.cell_sleeping;
    logEntry.reward = reward;
    appendJSONL("nonRT_log.jsonl", logEntry);

catch ME
    warning("[non-RT] t=%.3f s: 回调异常：%s", currentTime, ME.message);
end
end

%% ===== 状态收集（给 RIC） =====

function nearState = collectNearRTState(gNBs, ueServingCell, ueSmallCell, cellActive, appType)
numCells       = numel(gNBs);
numUEsPhysical = numel(ueServingCell);

nearState = struct();
nearState.numCells      = numCells;
nearState.numUEs        = numUEsPhysical;
nearState.ueServingCell = ueServingCell(:)';   % 当前使用的 cell（1=宏, 2..=微）
nearState.ueSmallCell   = ueSmallCell(:)';     % 每个 UE 的微小区编号
nearState.cellActive    = logical(cellActive(:))';
nearState.trafficType   = appType(:)';         % 1..4
nearState.useSmall      = (ueServingCell(:)' ~= 1);  % 当前是否走小小区
end

function nonRTState = collectNonRTState(gNBs, ueServingCell, ueSmallCell, cellActive, appType)
nonRTState = collectNearRTState(gNBs, ueServingCell, ueSmallCell, cellActive, appType);
end

%% ===== JSONL 追加写入（日志用） =====

function appendJSONL(filename, entry)
txt = jsonencode(entry);
fid = fopen(filename, "a");
if fid == -1
    warning("无法打开日志文件: %s", filename);
    return;
end
fprintf(fid, "%s\n", txt);
fclose(fid);
end

%% ===== 动作应用：Traffic Steering（在两条 leg 间通过 DataRate 切换业务） =====

function ueServingCell = applyTrafficSteeringFromPython( ...
    actions, ueServingCell, ueSmallCell, cellActive, ...
    dlTrafficMacro, dlTrafficSmall, appType, ...
    videoDataRateKbps, gamingDataRateKbps, ...
    voiceDataRateKbps, urllcDataRateKbps, lowDataRateKbps)

numUEsPhysical = numel(ueServingCell);
numCells       = numel(cellActive);

new_ueServingCell = ueServingCell;

if isfield(actions, 'traffic_steering')
    ts = actions.traffic_steering;
    if isfield(ts, 'use_small')
        useSmall = logical(ts.use_small);
        if numel(useSmall) == numUEsPhysical
            useSmall = useSmall(:);
            for p = 1:numUEsPhysical
                % 对应业务类型的"高速 DataRate"
                at = appType(p);
                switch at
                    case 1
                        highRate = videoDataRateKbps;
                    case 2
                        highRate = gamingDataRateKbps;
                    case 3
                        highRate = voiceDataRateKbps;
                    case 4
                        highRate = urllcDataRateKbps;
                    otherwise
                        highRate = videoDataRateKbps;
                end

                wantSmall = useSmall(p);
                smallCell = ueSmallCell(p);

                if wantSmall && smallCell >= 2 && smallCell <= numCells && cellActive(smallCell)
                    % 允许走小小区：宏 leg 降速，小 leg 升为高速
                    new_ueServingCell(p) = smallCell;
                    try, dlTrafficMacro{p}.DataRate = lowDataRateKbps;  end
                    try, dlTrafficSmall{p}.DataRate = highRate;        end
                else
                    % 走宏小区：宏 leg 高速，小 leg 低速
                    new_ueServingCell(p) = 1;
                    try, dlTrafficMacro{p}.DataRate = highRate;        end
                    try, dlTrafficSmall{p}.DataRate = lowDataRateKbps; end
                end
            end
        end
    end
end

ueServingCell = new_ueServingCell;
end

%% ===== 动作应用：Cell Sleeping（关小区 + UE 回落宏，通过 DataRate 控制） =====

function [cellActive, ueServingCell] = applyCellSleepingFromPython( ...
    actions, cellActive, ueSmallCell, ueServingCell, ...
    dlTrafficMacro, dlTrafficSmall, appType, ...
    videoDataRateKbps, gamingDataRateKbps, ...
    voiceDataRateKbps, urllcDataRateKbps, lowDataRateKbps)

numCells       = numel(cellActive);
numUEsPhysical = numel(ueServingCell);

new_cellActive = cellActive;

if isfield(actions, 'cell_sleeping')
    cs = actions.cell_sleeping;
    if isfield(cs, 'cell_active')
        act = logical(cs.cell_active);
        if numel(act) == numCells
            act = act(:);
            % 强制宏小区永远开
            act(1) = true;

            for c = 1:numCells
                old = cellActive(c);
                new = act(c);
                if new == old
                    continue;
                end

                if ~new
                    % active -> sleep：关该小区，相关 UE 微 leg 降速，必要时退回宏
                    for p = 1:numUEsPhysical
                        if ueSmallCell(p) == c
                            % 对应业务的"高速 DataRate"
                            at = appType(p);
                            switch at
                                case 1
                                    highRate = videoDataRateKbps;
                                case 2
                                    highRate = gamingDataRateKbps;
                                case 3
                                    highRate = voiceDataRateKbps;
                                case 4
                                    highRate = urllcDataRateKbps;
                                otherwise
                                    highRate = videoDataRateKbps;
                            end

                            % 小小区 leg 降为低速
                            try, dlTrafficSmall{p}.DataRate = lowDataRateKbps; end

                            % 如果当前正在走这个小区，则切回宏 + 提升宏 leg
                            if ueServingCell(p) == c
                                ueServingCell(p) = 1;
                                try, dlTrafficMacro{p}.DataRate = highRate; end
                            end
                        end
                    end
                else
                    % sleep -> active：只改变 cellActive，是否使用该小区由 near-RT RIC 决定
                end
            end

            new_cellActive = act;
        end
    end
end

cellActive = new_cellActive;
end

%% ===== KPI 提取 & 百分位数 =====

function [cellTputMbps, totalTputMbps] = extractCellThroughput(gNBStats, simulationTime)
numCells = numel(gNBStats);
cellTputMbps = nan(numCells,1);

for c = 1:numCells
    st = gNBStats(c);
    if isfield(st,"MAC") && isfield(st.MAC,"TransmittedBytes")
        bits = double(st.MAC.TransmittedBytes) * 8;
        cellTputMbps(c) = bits / simulationTime / 1e6;
    end
end

if all(isnan(cellTputMbps))
    totalTputMbps = nan;
else
    totalTputMbps = nansum(cellTputMbps);
end
end

function ueTputMbps = extractUEThroughput(ueStats, simulationTime)
numUEs = numel(ueStats);
ueTputMbps = nan(numUEs,1);

for u = 1:numUEs
    st = ueStats(u);
    if isfield(st,"MAC") && isfield(st.MAC,"ReceivedBytes")
        bits = double(st.MAC.ReceivedBytes) * 8;
        ueTputMbps(u) = bits / simulationTime / 1e6;
    end
end
end

function q = myQuantile(x, pVec)
x = x(:);
x = x(~isnan(x));
n = numel(x);
if n == 0
    q = nan(size(pVec));
    return;
end
x = sort(x);
q = nan(size(pVec));
for i = 1:numel(pVec)
    p = pVec(i);
    idx = ceil(p/100 * n);
    idx = max(1, min(n, idx));
    q(i) = x(idx);
end
end
