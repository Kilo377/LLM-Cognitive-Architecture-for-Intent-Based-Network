function results = oranSim_run_withPolicyHistory(totalTime, windowLen, policyIdxSeq)
% oranSim_run_withPolicyHistory.m
%
% 按"策略时间表"从 t=0 跑到 totalTime。
%
% 用法示例（MATLAB 里）：
%   % 以 1 秒为窗口，一共 5 个窗口，对应策略 ID [1 2 1 3 2]
%   totalTime   = 5.0;
%   windowLen   = 1.0;
%   policyIdxSeq = [1 2 1 3 2];
%   results = oranSim_run_withPolicyHistory(totalTime, windowLen, policyIdxSeq);
%
% 约定：
%   - policyIdxSeq(k) 是第 k 个窗口的策略 ID
%   - 第 k 个窗口时间范围：[(k-1)*windowLen, k*windowLen)
%   - 如果 totalTime 超出最后一个窗口，会自动截断在最后一个策略上。

%% ===== 默认参数（兼容不传参的用法） =====
if nargin < 1 || isempty(totalTime)
    totalTime = 5.0;   % 默认跑 5 秒
end
if nargin < 2 || isempty(windowLen)
    windowLen = 1.0;   % 默认窗口 1 秒
end
if nargin < 3 || isempty(policyIdxSeq)
    policyIdxSeq = 1;  % 默认全程用策略 1
end

policyIdxSeq = policyIdxSeq(:)';  % 统一转成行向量

%% ===== 全局变量：场景 + RIC 状态 + 策略时间表 =====
global RIC_gNBs RIC_allUEs
global RIC_ueServingCell RIC_ueSmallCell RIC_cellActive RIC_appType
global RIC_dlTrafficMacro RIC_dlTrafficSmall
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate RIC_lowRate
global RIC_numUEsPhysical

% 新增：策略时间表相关
global RIC_windowLen RIC_policyIdxSeq

RIC_windowLen   = windowLen;
RIC_policyIdxSeq = policyIdxSeq;

%% 1) 初始化场景（每次从 0 重跑一遍）

env = oranScenarioInit_light();  % 使用你现有的场景初始化函数

networkSimulator   = env.networkSimulator;
simulationTimeEnv  = env.simulationTime;   % 仿真器上限，例如 10 s

gNBs               = env.gNBs;
allUEs             = env.allUEs;

numCells           = numel(gNBs);
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

% 存进全局（供回调使用）
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

RIC_numUEsPhysical = numUEsPhysical;

%% 2) 限制 totalTime 不超过仿真器上限

targetSimTime = totalTime;
if targetSimTime > simulationTimeEnv
    warning("totalTime=%.2f 超过仿真器上限 %.2f，自动截断到上限。", ...
        targetSimTime, simulationTimeEnv);
    targetSimTime = simulationTimeEnv;
end

%% 3) 启用 MATLAB RIC：near-RT + non-RT（Beam RIC 在自定义 scheduler 里）

useRIC       = true;  % 如果想跑 baseline，把这里改成 false
nearRTStep   = 0.05;  % 50 ms 触发一次 near-RT RIC
nonRTPeriod  = 1.0;   % 1  s  触发一次 non-RT RIC

fprintf("开始仿真（策略时间表 + MATLAB RIC），目标时长 %.2f 秒（仿真器上限 %.2f 秒）...\n", ...
    targetSimTime, simulationTimeEnv);

if ~useRIC
    % baseline：不调用任何 RIC，仅用 toolbox 默认 scheduler + 你配置的 Beam Scheduler
    run(networkSimulator, targetSimTime);
    actualSimTime = targetSimTime;
else
    % 传给回调的 userdata（目前只需要 Simulator 本身）
    userdataNear  = struct("Simulator", networkSimulator);
    userdataNonRT = struct("Simulator", networkSimulator);

    % 周期调用 near-RT RIC（Traffic Steering）
    scheduleAction(networkSimulator, @nearRTCallback_policyAware, userdataNear,  0.0, nearRTStep);

    % 周期调用 non-RT RIC（Cell Sleeping）
    scheduleAction(networkSimulator, @nonRTCallback_policyAware,  userdataNonRT, 0.5, nonRTPeriod);

    % 一次性跑完 targetSimTime（0 → targetSimTime）
    run(networkSimulator, targetSimTime);
    actualSimTime = targetSimTime;
end

fprintf("仿真结束。\n");

%% 4) KPI：吞吐统计（和你原来的基本一致）

gNBStats = statistics(gNBs);
ueStats  = statistics(allUEs);

[cellTputMbps, totalTputMbps] = extractCellThroughput(gNBStats, actualSimTime);
ueTputLegMbps = extractUEThroughput(ueStats, actualSimTime);   % 对应 allUEs，每个物理 UE 两条 leg

fprintf("\n===== KPI 输出（全程） =====\n");

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

%% 5) 返回一个结构体，方便 Python / 外部脚本使用

results = struct();
results.actualSimTime   = actualSimTime;
results.cellTputMbps    = cellTputMbps;
results.totalTputMbps   = totalTputMbps;
results.ueTputLegMbps   = ueTputLegMbps;
results.numCells        = numCells;
results.numUEsPhysical  = numUEsPhysical;

end  % 主函数结束


%% ====== 带"策略时间表"的 near-RT 回调 ======
function nearRTCallback_policyAware(actionID, userdata) %#ok<INUSD>
% 每 50 ms 调一次：Traffic Steering（MATLAB 实现）
%
% 和你原来的 nearRTCallback 基本一致，只是多了一步：
%   - 根据当前仿真时间，查"策略时间表"，得到当前 policyId
%   - 把 policyId 塞进 logEntry.info.policyId 里，方便 RL 离线学习

global RIC_gNBs
global RIC_ueServingCell RIC_ueSmallCell RIC_cellActive RIC_appType
global RIC_dlTrafficMacro RIC_dlTrafficSmall
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate RIC_lowRate

% 新增：策略时间表
global RIC_windowLen RIC_policyIdxSeq

sim = userdata.Simulator;
currentTime = sim.CurrentTime;

% === 1) 计算当前策略 ID（根据仿真时间在哪个窗口） ===
policyId = 0;
if ~isempty(RIC_windowLen) && RIC_windowLen > 0 && ~isempty(RIC_policyIdxSeq)
    segIdx = floor(currentTime / RIC_windowLen) + 1;
    segIdx = min(segIdx, numel(RIC_policyIdxSeq));
    policyId = RIC_policyIdxSeq(segIdx);
end

try
    % 2) 组装 state（含 qL, LR）
    state = collectNearRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 3) 调用 nearRT_ric：内部已经保证不能把 UE 切到休眠小区
    [useSmall, reward, info] = nearRT_ric(state);

    % 在 info 里记录当前策略 ID
    info.policyId = policyId;

    % 4) 应用动作
    actionsNearRT = struct();
    actionsNearRT.traffic_steering = struct("use_small", useSmall(:)');

    RIC_ueServingCell = applyTrafficSteeringFromPython( ...
        actionsNearRT, RIC_ueServingCell, RIC_ueSmallCell, RIC_cellActive, ...
        RIC_dlTrafficMacro, RIC_dlTrafficSmall, RIC_appType, ...
        RIC_videoRate, RIC_gamingRate, RIC_voiceRate, RIC_urllcRate, RIC_lowRate);

    % 5) next_state
    nextState = collectNearRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 6) 记录 nearRT transition（所有 step 都记录）
    logEntry = struct();
    logEntry.time       = currentTime;
    logEntry.state      = state;
    logEntry.action     = actionsNearRT.traffic_steering;
    logEntry.reward     = reward;
    logEntry.next_state = nextState;
    logEntry.info       = info;  % 里面已经带 policyId

    appendJSONL("nearRT_log.jsonl", logEntry);

catch ME
    warning("[near-RT] t=%.3f s: 回调异常：%s", currentTime, ME.message);
end
end


%% ====== 带"策略时间表"的 non-RT 回调 ======
function nonRTCallback_policyAware(actionID, userdata) %#ok<INUSD>
% 每 1 s 调一次：Cell Sleeping（MATLAB 实现）
% 同样：多了一步 policyId 记录

global RIC_gNBs
global RIC_ueServingCell RIC_ueSmallCell RIC_cellActive RIC_appType
global RIC_dlTrafficMacro RIC_dlTrafficSmall
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate RIC_lowRate

global RIC_windowLen RIC_policyIdxSeq

sim = userdata.Simulator;
currentTime = sim.CurrentTime;

% 1) 当前策略 ID
policyId = 0;
if ~isempty(RIC_windowLen) && RIC_windowLen > 0 && ~isempty(RIC_policyIdxSeq)
    segIdx = floor(currentTime / RIC_windowLen) + 1;
    segIdx = min(segIdx, numel(RIC_policyIdxSeq));
    policyId = RIC_policyIdxSeq(segIdx);
end

try
    % 2) 组装 state（含 qL, LR）
    state = collectNonRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 3) 调用 nonRT_ric
    [cellActiveAction, reward, info] = nonRT_ric(state);

    % 在 info 里记录策略 ID
    info.policyId = policyId;

    % 4) 应用动作（更新 cellActive + UE 回落宏 + DataRate）
    actionsNonRT = struct();
    actionsNonRT.cell_sleeping = struct("cell_active", cellActiveAction(:)');

    [RIC_cellActive, RIC_ueServingCell] = applyCellSleepingFromPython( ...
        actionsNonRT, RIC_cellActive, RIC_ueSmallCell, RIC_ueServingCell, ...
        RIC_dlTrafficMacro, RIC_dlTrafficSmall, RIC_appType, ...
        RIC_videoRate, RIC_gamingRate, RIC_voiceRate, RIC_urllcRate, RIC_lowRate);

    % 5) next_state
    nextState = collectNonRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 6) 记录 nonRT transition
    logEntry = struct();
    logEntry.time       = currentTime;
    logEntry.state      = state;
    logEntry.action     = actionsNonRT.cell_sleeping;
    logEntry.reward     = reward;
    logEntry.next_state = nextState;
    logEntry.info       = info;

    appendJSONL("nonRT_log.jsonl", logEntry);

catch ME
    warning("[non-RT] t=%.3f s: 回调异常：%s", currentTime, ME.message);
end
end


%% ===== 状态收集（保持你原来的实现） =====
function nearState = collectNearRTState(gNBs, ueServingCell, ueSmallCell, cellActive, appType)
numCells       = numel(gNBs);
numUEsPhysical = numel(ueServingCell);

[qL, LR] = computeBSLoadFeatures(ueServingCell, appType, numCells);

nearState = struct();
nearState.numCells      = numCells;
nearState.numUEs        = numUEsPhysical;
nearState.ueServingCell = ueServingCell(:)';   % 当前使用的 cell
nearState.ueSmallCell   = ueSmallCell(:)';     % 每个 UE 的微小区编号
nearState.cellActive    = logical(cellActive(:))';
nearState.trafficType   = appType(:)';         % 1..4
nearState.useSmall      = (ueServingCell(:)' ~= 1);  % 当前是否走小小区
nearState.qL            = qL;                  % 每小区名义业务速率和（kbps）
nearState.LR            = LR;                  % 归一化负载比例
end

function nonRTState = collectNonRTState(gNBs, ueServingCell, ueSmallCell, cellActive, appType)
numCells       = numel(gNBs);
numUEsPhysical = numel(ueServingCell);

[qL, LR] = computeBSLoadFeatures(ueServingCell, appType, numCells);

nonRTState = struct();
nonRTState.numCells      = numCells;
nonRTState.numUEs        = numUEsPhysical;
nonRTState.ueServingCell = ueServingCell(:)';   % 当前使用的 cell
nonRTState.ueSmallCell   = ueSmallCell(:)';     % 每个 UE 的微小区编号
nonRTState.cellActive    = logical(cellActive(:))';
nonRTState.trafficType   = appType(:)';         % 1..4
nonRTState.qL            = qL;                  % 每小区名义业务速率和（kbps）
nonRTState.LR            = LR;                  % 归一化负载比例
end

function [qL, LR] = computeBSLoadFeatures(ueServingCell, appType, numCells)
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate

numUEsPhysical = numel(ueServingCell);

offeredLoadKbps = zeros(1, numCells);

for p = 1:numUEsPhysical
    c = ueServingCell(p);
    if c < 1 || c > numCells
        continue;
    end

    at = appType(p);
    switch at
        case 1, highRate = RIC_videoRate;
        case 2, highRate = RIC_gamingRate;
        case 3, highRate = RIC_voiceRate;
        case 4, highRate = RIC_urllcRate;
        otherwise, highRate = RIC_videoRate;
    end

    offeredLoadKbps(c) = offeredLoadKbps(c) + double(highRate);
end

qL = offeredLoadKbps;
totalLoad = sum(offeredLoadKbps);
if totalLoad > 0
    LR = offeredLoadKbps / totalLoad;
else
    LR = zeros(1, numCells);
end
end

%% ===== JSONL 追加写入 =====
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

%% ===== 动作应用：Traffic Steering & Cell Sleeping（与你现有版本一致） =====
function ueServingCell = applyTrafficSteeringFromPython( ...
    actions, ueServingCell, ueSmallCell, cellActive, ...
    dlTrafficMacro, dlTrafficSmall, appType, ...
    videoDataRateKbps, gamingDataRateKbps, ...
    voiceDataRateKbps, urllcDataRateKbps, lowDataRateKbps)

numUEsPhysical = numel(ueServingCell);
numCells       = numel(cellActive);

new_ueServingCell = ueServingCell;

if isfield(actions, "traffic_steering")
    ts = actions.traffic_steering;
    if isfield(ts, "use_small")
        useSmall = logical(ts.use_small);
        if numel(useSmall) == numUEsPhysical
            useSmall = useSmall(:);
            for p = 1:numUEsPhysical
                at = appType(p);
                switch at
                    case 1, highRate = videoDataRateKbps;
                    case 2, highRate = gamingDataRateKbps;
                    case 3, highRate = voiceDataRateKbps;
                    case 4, highRate = urllcDataRateKbps;
                    otherwise, highRate = videoDataRateKbps;
                end

                wantSmall = useSmall(p);
                smallCell = ueSmallCell(p);

                if wantSmall && smallCell >= 2 && smallCell <= numCells && cellActive(smallCell)
                    new_ueServingCell(p) = smallCell;
                    try, dlTrafficMacro{p}.DataRate = lowDataRateKbps;  end
                    try, dlTrafficSmall{p}.DataRate = highRate;        end
                else
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

function [cellActive, ueServingCell] = applyCellSleepingFromPython( ...
    actions, cellActive, ueSmallCell, ueServingCell, ...
    dlTrafficMacro, dlTrafficSmall, appType, ...
    videoDataRateKbps, gamingDataRateKbps, ...
    voiceDataRateKbps, urllcDataRateKbps, lowDataRateKbps)

numCells       = numel(cellActive);
numUEsPhysical = numel(ueServingCell);

new_cellActive = cellActive;

if isfield(actions, "cell_sleeping")
    cs = actions.cell_sleeping;
    if isfield(cs, "cell_active")
        act = logical(cs.cell_active);
        if numel(act) == numCells
            act = act(:);
            act(1) = true;  % 宏小区永远开

            for c = 1:numCells
                old = cellActive(c);
                new = act(c);
                if new == old
                    continue;
                end

                if ~new
                    % active -> sleep
                    for p = 1:numUEsPhysical
                        if ueSmallCell(p) == c
                            switch appType(p)
                                case 1, highRate = videoDataRateKbps;
                                case 2, highRate = gamingDataRateKbps;
                                case 3, highRate = voiceDataRateKbps;
                                case 4, highRate = urllcDataRateKbps;
                                otherwise, highRate = videoDataRateKbps;
                            end

                            try, dlTrafficSmall{p}.DataRate = lowDataRateKbps; end

                            if ueServingCell(p) == c
                                ueServingCell(p) = 1;
                                try, dlTrafficMacro{p}.DataRate = highRate; end
                            end
                        end
                    end
                else
                    % sleep -> active：只更新 cellActive，其它留给 near-RT 决策
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
