function [simKPI, cellEntry, ueEntry] = oranSim_RL_step_light(prevPolicy, currPolicy)
% oranSim_RL_step_light
% LIGHT VERSION + 双 UE + DataRate 切换 + Beam RIC（码本波束成形）
%
% - 使用 oranScenarioInit_light() 搭好场景
% - 支持：
%   * near-RT RIC:  Traffic Steering (App1)，每 50 ms（DataRate + 宏/微切换）
%   * non-RT RIC:   Cell Sleeping    (App2)，每 1  s（小区开关 + EE）
%   * Beam RIC:     物理级码本选择（自定义 nrScheduler：RICBeamScheduler）
% - two-phase 版本：
%   * prevPhaseDuration:  第一阶段（prev 策略）持续时间
%   * currPhaseDuration:  第二阶段（curr 策略）持续时间
%   * KPI 只统计第二阶段：基于 phaseSplitTime 之后的 MAC Bytes 增量
%
% 输入（可选）：
%   prevPolicy.nonRT / .nearRT / .beam : 上一轮策略 ID（字符串）
%   currPolicy.nonRT / .nearRT / .beam : 当前轮策略 ID（字符串）
%
% 若无输入参数，则使用 baseline 策略并 prev==curr。

%% ===== 0) 处理可选输入（允许无参调用） =====
if nargin < 1 || isempty(prevPolicy)
    prevPolicy = struct( ...
        "nonRT",  "nonrt_baseline", ...
        "nearRT", "nearrt_macro_only", ...
        "beam",   "beam_default");
end
if nargin < 2 || isempty(currPolicy)
    currPolicy = prevPolicy;
end

%% ===== 全局变量，用于 RIC 回调和 Summary 回调共享状态 =====
global RIC_gNBs RIC_allUEs
global RIC_ueServingCell RIC_ueSmallCell RIC_cellActive RIC_appType
global RIC_dlTrafficMacro RIC_dlTrafficSmall
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate RIC_lowRate
global RIC_numUEsPhysical
global RIC_macroUEIndices RIC_smallUEIndices

% Summary 相关的全局：用于计算"过去 dt 内"的吞吐
global RIC_prevCellTxBytes RIC_prevUERxBytes RIC_prevTime

% second-phase KPI 相关：在 phaseSplitTime 记录基线 bytes
global RIC_phaseSplitTime
global RIC_cellTxBytesAtSplit RIC_ueRxBytesAtSplit RIC_phaseSplitDone

%% 1) 是否启用 RIC
useRIC = true;  % baseline 时改成 false，则只跑固定 scheduler + 固定 DataRate/小区

%% 2) 初始化场景
env = oranScenarioInit_light();

networkSimulator   = env.networkSimulator;
simulationTimeEnv  = env.simulationTime;   % 仿真器上限，例如 10 s

% ==== two-phase 配置（你可以改成 5+5，只要总和不超过 simulationTimeEnv）====
prevPhaseDuration = 1.0;  % 第一阶段（prev 策略）持续时间
currPhaseDuration = 1.0;  % 第二阶段（curr 策略）持续时间

targetSimTime      = prevPhaseDuration + currPhaseDuration;
phaseSplitTime     = prevPhaseDuration;
RIC_phaseSplitTime = phaseSplitTime;

gNBs               = env.gNBs;
allUEs             = env.allUEs;

numCells           = numel(gNBs);
numUEsPhysical     = env.numUEsPhysical;
macroUEIndices     = env.macroUEIndices;
smallUEIndices     = env.smallUEIndices;
ueSmallCell        = env.ueSmallCell;

ueServingCell      = env.ueServingCell;   % 1 = 宏, 2..numCells = 微（初始全 1）
cellActive         = env.cellActive;
appType            = env.appType;

dlTrafficMacro     = env.dlTrafficMacro;
dlTrafficSmall     = env.dlTrafficSmall;

videoDataRateKbps  = env.videoDataRateKbps;
gamingDataRateKbps = env.gamingDataRateKbps;
voiceDataRateKbps  = env.voiceDataRateKbps;
urllcDataRateKbps  = env.urllcDataRateKbps;
lowDataRateKbps    = env.lowDataRateKbps;

% 存进全局，方便 RIC / Summary 回调访问
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
RIC_macroUEIndices = macroUEIndices;
RIC_smallUEIndices = smallUEIndices;

% 初始化 Summary 所需的"上一时刻统计值"
RIC_prevTime         = 0.0;
RIC_prevCellTxBytes  = zeros(numCells,1);
RIC_prevUERxBytes    = zeros(numel(allUEs),1);  % 对每个 UE leg 记之前的 RX Bytes

% 初始化 second-phase 基线
RIC_cellTxBytesAtSplit = zeros(numCells,1);
RIC_ueRxBytesAtSplit   = zeros(numel(allUEs),1);
RIC_phaseSplitDone     = false;   % 标记"是否已记录基线"

%% 2.5) 配置 RIC 策略（prev / curr）
% 这里检测一下 setupRicPoliciesTwoPhase 的签名，兼容你目录里旧版本
if exist('setupRicPoliciesTwoPhase', 'file')
    try
        if nargin('setupRicPoliciesTwoPhase') >= 2
            setupRicPoliciesTwoPhase(prevPolicy, currPolicy);
        else
            % 旧版本没有参数，就直接调用，让它内部用固定策略
            setupRicPoliciesTwoPhase();
        end
    catch ME
        warning("setupRicPoliciesTwoPhase 调用失败：%s", ME.message);
    end
end

%% 3) baseline：不开 RIC（只用自带 scheduler + BeamScheduler 的默认行为）
if ~useRIC
    fprintf("开始 LIGHT baseline 仿真（不调用 RIC），总时长 %.2f 秒...\n", targetSimTime);
    run(networkSimulator, targetSimTime);
    fprintf("仿真结束。\n");
    actualSimTime = targetSimTime;

else
    %% 4) 启用 MATLAB RIC（near-RT + non-RT；Beam RIC 在自定义 scheduler 里）
    nearRTStep     = 0.05;   % 50 ms
    nonRTPeriod    = 1.0;    % 1  s
    summaryPeriod  = 0.5;    % 0.5 s 生成一次综合 KPI 快照

    if targetSimTime > simulationTimeEnv
        warning("targetSimTime=%.2f 超过仿真器上限 %.2f，自动截断到上限。", ...
            targetSimTime, simulationTimeEnv);
        targetSimTime = simulationTimeEnv;
    end

    fprintf("开始 two-phase 仿真（RIC+Beam+Summary），总时长 %.2f s，策略切换 %.2f s...\n", ...
        targetSimTime, phaseSplitTime);

    userdataNear    = struct("Simulator", networkSimulator);
    userdataNonRT   = struct("Simulator", networkSimulator);
    userdataSummary = struct("Simulator", networkSimulator);

    % 周期调用 near-RT RIC（Traffic Steering）
    scheduleAction(networkSimulator, @nearRTCallback, userdataNear,  0,   nearRTStep);

    % 周期调用 non-RT RIC（Cell Sleeping）
    scheduleAction(networkSimulator, @nonRTCallback,  userdataNonRT, 0.5, nonRTPeriod);

    % 周期调用 Summary（每 0.5 s 记录一次 KPI + 负责在 split 时刻记录 second-phase 基线）
    scheduleAction(networkSimulator, @summaryCallback, userdataSummary, 0.5, summaryPeriod);

    % 仿真一次性跑完 targetSimTime
    run(networkSimulator, targetSimTime);

    fprintf("仿真结束。\n");
    actualSimTime = targetSimTime;
end

%% 5) 最后做一次 second-phase KPI（只统计 [phaseSplitTime, targetSimTime]）

[simKPI, cellEntry, ueEntry] = computeSecondPhaseKPI( ...
    gNBs, allUEs, ...
    macroUEIndices, smallUEIndices, numUEsPhysical, ...
    numCells, ...
    RIC_cellTxBytesAtSplit, RIC_ueRxBytesAtSplit, ...
    phaseSplitTime, actualSimTime, ...
    RIC_cellActive, RIC_ueServingCell, RIC_appType);

fprintf("\n===== LIGHT MODE KPI (%.2f~%.2f s, second phase) =====\n", ...
    phaseSplitTime, actualSimTime);

for c = 1:numCells
    fprintf("  小区 %d 下行平均吞吐 ≈ %.2f Mbps\n", c, simKPI.cellTputMbps(c));
end
fprintf("  => 总下行平均吞吐 ≈ %.2f Mbps\n", simKPI.totalTputMbps);
fprintf("  物理 UE 吞吐分布 (Mbps): 5%%=%.2f, 50%%=%.2f, 95%%=%.2f\n", ...
    simKPI.ueTput5, simKPI.ueTput50, simKPI.ueTput95);

fprintf("===== 结束 =====\n");

end  % function oranSim_RL_step_light

%% ====== RIC 回调函数 ======

function nearRTCallback(~, userdata)
% 每 50 ms 调一次：Traffic Steering（MATLAB 实现）

global RIC_gNBs
global RIC_ueServingCell RIC_ueSmallCell RIC_cellActive RIC_appType
global RIC_dlTrafficMacro RIC_dlTrafficSmall
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate RIC_lowRate

sim = userdata.Simulator;
currentTime = sim.CurrentTime;

try
    % 1) 组装 state（含 qL, LR）
    state = collectNearRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 2) 调用 nearRT_ric：内部已经保证不能把 UE 切到休眠小区
    [useSmall, reward, info] = nearRT_ric(state);

    % 3) 应用动作
    actionsNearRT = struct();
    actionsNearRT.traffic_steering = struct("use_small", useSmall(:)');

    RIC_ueServingCell = applyTrafficSteeringFromPython( ...
        actionsNearRT, RIC_ueServingCell, RIC_ueSmallCell, RIC_cellActive, ...
        RIC_dlTrafficMacro, RIC_dlTrafficSmall, RIC_appType, ...
        RIC_videoRate, RIC_gamingRate, RIC_voiceRate, RIC_urllcRate, RIC_lowRate);

    % 4) next_state
    nextState = collectNearRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 5) 记录 nearRT transition（所有 step 都记录）
    logEntry = struct();
    logEntry.time       = currentTime;
    logEntry.state      = state;
    logEntry.action     = actionsNearRT.traffic_steering;
    logEntry.reward     = reward;
    logEntry.next_state = nextState;
    logEntry.info       = info;

    appendJSONL("nearRT_log.jsonl", logEntry);

catch ME
    warning("[near-RT] t=%.3f s: 回调异常：%s", currentTime, ME.message);
end
end

function nonRTCallback(~, userdata)
% 每 1 s 调一次：Cell Sleeping（MATLAB 实现）

global RIC_gNBs
global RIC_ueServingCell RIC_ueSmallCell RIC_cellActive RIC_appType
global RIC_dlTrafficMacro RIC_dlTrafficSmall
global RIC_videoRate RIC_gamingRate RIC_voiceRate RIC_urllcRate RIC_lowRate

sim = userdata.Simulator;
currentTime = sim.CurrentTime;

try
    % 1) 组装 state（含 qL, LR）
    state = collectNonRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 2) 调用 nonRT_ric
    [cellActiveAction, reward, info] = nonRT_ric(state);

    % 3) 应用动作（更新 cellActive + UE 回落宏 + DataRate）
    actionsNonRT = struct();
    actionsNonRT.cell_sleeping = struct("cell_active", cellActiveAction(:)');

    [RIC_cellActive, RIC_ueServingCell] = applyCellSleepingFromPython( ...
        actionsNonRT, RIC_cellActive, RIC_ueSmallCell, RIC_ueServingCell, ...
        RIC_dlTrafficMacro, RIC_dlTrafficSmall, RIC_appType, ...
        RIC_videoRate, RIC_gamingRate, RIC_voiceRate, RIC_urllcRate, RIC_lowRate);

    % 4) next_state
    nextState = collectNonRTState(RIC_gNBs, RIC_ueServingCell, ...
        RIC_ueSmallCell, RIC_cellActive, RIC_appType);

    % 5) 记录 nonRT transition
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

%% ===== Summary 回调：每 0.5s 输出一次 KPI 快照 + 在 split 时记录基线 =====

function summaryCallback(~, userdata)
global RIC_gNBs RIC_allUEs
global RIC_ueServingCell RIC_cellActive RIC_appType
global RIC_numUEsPhysical RIC_macroUEIndices RIC_smallUEIndices
global RIC_prevCellTxBytes RIC_prevUERxBytes RIC_prevTime

% second-phase 基线相关
global RIC_phaseSplitTime RIC_cellTxBytesAtSplit RIC_ueRxBytesAtSplit RIC_phaseSplitDone

sim = userdata.Simulator;
currentTime = sim.CurrentTime;

try
    % 每次 summary 都先取一次当前 stats
    gNBStats = statistics(RIC_gNBs);
    ueStats  = statistics(RIC_allUEs);

    % ==== 若尚未记录基线且当前时间 >= splitTime，则在此刻记录 ====
    if ~RIC_phaseSplitDone && currentTime >= RIC_phaseSplitTime
        recordSecondPhaseBaseline(gNBStats, ueStats);
        RIC_phaseSplitDone = true;
        fprintf("[Split] t=%.3f s: 已记录 second-phase 基线字节。\n", currentTime);
    end

    % 第一次调用（RIC_prevTime == 0）：只初始化 prev 统计，不写 summary JSON
    if RIC_prevTime == 0
        numCells = numel(gNBStats);
        numUEs   = numel(ueStats);

        RIC_prevCellTxBytes = zeros(numCells,1);
        for c = 1:numCells
            if isfield(gNBStats(c),"MAC") && isfield(gNBStats(c).MAC,"TransmittedBytes")
                RIC_prevCellTxBytes(c) = double(gNBStats(c).MAC.TransmittedBytes);
            else
                RIC_prevCellTxBytes(c) = 0;
            end
        end

        RIC_prevUERxBytes = zeros(numUEs,1);
        for u = 1:numUEs
            if isfield(ueStats(u),"MAC") && isfield(ueStats(u).MAC,"ReceivedBytes")
                RIC_prevUERxBytes(u) = double(ueStats(u).MAC.ReceivedBytes);
            else
                RIC_prevUERxBytes(u) = 0;
            end
        end

        RIC_prevTime = currentTime;
        return;
    end

    dt = currentTime - RIC_prevTime;
    if dt <= 0
        return;
    end

    numCells = numel(gNBStats);
    numUEsLeg = numel(ueStats);
    numUEsPhys = RIC_numUEsPhysical;

    %% === 1) cell 级瞬时吞吐 ===
    cellTputInst = zeros(numCells,1);
    cellTxBytesNow = zeros(numCells,1);

    for c = 1:numCells
        if isfield(gNBStats(c),"MAC") && isfield(gNBStats(c).MAC,"TransmittedBytes")
            txB = double(gNBStats(c).MAC.TransmittedBytes);
        else
            txB = 0;
        end
        cellTxBytesNow(c) = txB;
        deltaB = txB - RIC_prevCellTxBytes(c);
        if deltaB < 0
            deltaB = 0;
        end
        cellTputInst(c) = deltaB * 8 / dt / 1e6;
    end

    %% === 2) M/M/1 时延 + 功耗估计 ===
    cellUserCount = zeros(numCells,1);
    for p = 1:numUEsPhys
        c = RIC_ueServingCell(p);
        if c >= 1 && c <= numCells
            cellUserCount(c) = cellUserCount(c) + 1;
        end
    end
    cellLoadRatio = cellUserCount / max(1, numUEsPhys);

    BASE_DELAY_MACRO = 10.0; % ms
    BASE_DELAY_SMALL = 5.0;  % ms

    P_MACRO_ON    = 1.0;
    P_SMALL_ON    = 0.5;
    P_SMALL_SLEEP = 0.1;

    cellDelayMs = zeros(numCells,1);
    cellPower   = zeros(numCells,1);
    cellEE      = zeros(numCells,1);

    for c = 1:numCells
        rho = min(cellLoadRatio(c), 0.99);
        if c == 1
            baseDelay = BASE_DELAY_MACRO;
            cellPower(c) = P_MACRO_ON;
        else
            baseDelay = BASE_DELAY_SMALL;
            if RIC_cellActive(c)
                cellPower(c) = P_SMALL_ON;
            else
                cellPower(c) = P_SMALL_SLEEP;
            end
        end

        cellDelayMs(c) = baseDelay / (1 - rho);

        if cellPower(c) > 0
            cellEE(c) = cellTputInst(c) / cellPower(c);
        else
            cellEE(c) = 0;
        end
    end

    %% === 3) UE 级瞬时吞吐 / 时延 / 能效 ===
    ueTputInst = zeros(numUEsPhys,1);
    ueDelayMs  = zeros(numUEsPhys,1);
    ueEE       = zeros(numUEsPhys,1);

    ueRxBytesNow = zeros(numUEsLeg,1);
    for u = 1:numUEsLeg
        if isfield(ueStats(u),"MAC") && isfield(ueStats(u).MAC,"ReceivedBytes")
            ueRxBytesNow(u) = double(ueStats(u).MAC.ReceivedBytes);
        else
            ueRxBytesNow(u) = 0;
        end
    end

    for p = 1:numUEsPhys
        idxM = RIC_macroUEIndices(p);
        idxS = RIC_smallUEIndices(p);

        rxM_now = (idxM >= 1 && idxM <= numUEsLeg) * ueRxBytesNow(idxM);
        rxS_now = (idxS >= 1 && idxS <= numUEsLeg) * ueRxBytesNow(idxS);

        rxM_prev = (idxM >= 1 && idxM <= numUEsLeg) * RIC_prevUERxBytes(idxM);
        rxS_prev = (idxS >= 1 && idxS <= numUEsLeg) * RIC_prevUERxBytes(idxS);

        deltaB = (rxM_now - rxM_prev) + (rxS_now - rxS_prev);
        if deltaB < 0
            deltaB = 0;
        end

        ueTputInst(p) = deltaB * 8 / dt / 1e6;  % Mbps

        c = RIC_ueServingCell(p);
        if c >= 1 && c <= numCells
            ueDelayMs(p) = cellDelayMs(c);
            if cellPower(c) > 0
                ueEE(p) = ueTputInst(p) / cellPower(c);
            else
                ueEE(p) = 0;
            end
        else
            ueDelayMs(p) = 0;
            ueEE(p)      = 0;
        end
    end

    %% === 4) 写 JSONL summary ===
    cellEntry = struct();
    cellEntry.time_sec         = currentTime;
    cellEntry.cell_id          = 1:numCells;
    cellEntry.throughput_Mbps  = cellTputInst(:)';
    cellEntry.delay_ms         = cellDelayMs(:)';
    cellEntry.load_ratio       = cellLoadRatio(:)';
    cellEntry.power_norm       = cellPower(:)';
    cellEntry.energyEff_MbpsPerPower = cellEE(:)';

    appendJSONL("summary_cell.jsonl", cellEntry);

    ueEntry = struct();
    ueEntry.time_sec        = currentTime;
    ueEntry.ue_id           = 1:numUEsPhys;
    ueEntry.serving_cell    = RIC_ueServingCell(:)';
    ueEntry.throughput_Mbps = ueTputInst(:)';
    ueEntry.delay_ms        = ueDelayMs(:)';
    ueEntry.energyEff_MbpsPerPower = ueEE(:)';

    appendJSONL("summary_ue.jsonl", ueEntry);

    %% === 5) 更新 prev 统计 ===
    RIC_prevTime = currentTime;
    RIC_prevCellTxBytes = cellTxBytesNow;
    RIC_prevUERxBytes   = ueRxBytesNow;

catch ME
    warning("[Summary] t=%.3f s: 回调异常：%s", currentTime, ME.message);
end
end

%% ===== second-phase 基线记录 =====

function recordSecondPhaseBaseline(gNBStats, ueStats)
% 从当前 gNBStats / ueStats 里把 Bytes 抽出来，写到全局基线数组
global RIC_cellTxBytesAtSplit RIC_ueRxBytesAtSplit

numCells = numel(gNBStats);
numUEs   = numel(ueStats);

RIC_cellTxBytesAtSplit = zeros(numCells,1);
for c = 1:numCells
    if isfield(gNBStats(c),"MAC") && isfield(gNBStats(c).MAC,"TransmittedBytes")
        RIC_cellTxBytesAtSplit(c) = double(gNBStats(c).MAC.TransmittedBytes);
    end
end

RIC_ueRxBytesAtSplit = zeros(numUEs,1);
for u = 1:numUEs
    if isfield(ueStats(u),"MAC") && isfield(ueStats(u).MAC,"ReceivedBytes")
        RIC_ueRxBytesAtSplit(u) = double(ueStats(u).MAC.ReceivedBytes);
    end
end
end

%% ===== second-phase KPI 计算（只看 [tStart, tEnd] 增量） =====

function [simKPI, cellEntry, ueEntry] = computeSecondPhaseKPI( ...
    gNBs, allUEs, ...
    macroUEIndices, smallUEIndices, numUEsPhysical, ...
    numCells, ...
    cellTxBytesBase, ueRxBytesBase, ...
    tStart, tEnd, ...
    cellActive, ueServingCell, appType)

Tcurr = max(1e-3, tEnd - tStart);

gNBStats_end = statistics(gNBs);
ueStats_end  = statistics(allUEs);

numUEsLeg = numel(ueStats_end);

cellTputMbps = zeros(numCells,1);
for c = 1:numCells
    if isfield(gNBStats_end(c),"MAC") && isfield(gNBStats_end(c).MAC,"TransmittedBytes")
        txEnd = double(gNBStats_end(c).MAC.TransmittedBytes);
    else
        txEnd = 0;
    end
    if c >= 1 && c <= numel(cellTxBytesBase)
        txBase = double(cellTxBytesBase(c));
    else
        txBase = 0;
    end
    deltaB = max(0, txEnd - txBase);
    cellTputMbps(c) = deltaB * 8 / Tcurr / 1e6;
end
totalTputMbps = sum(cellTputMbps);

ueTputPhys = zeros(numUEsPhysical,1);
for p = 1:numUEsPhysical
    idxM = macroUEIndices(p);
    idxS = smallUEIndices(p);

    rxEndM = getUEBytes(ueStats_end, idxM);
    rxEndS = getUEBytes(ueStats_end, idxS);

    baseM  = getArraySafe(ueRxBytesBase, idxM);
    baseS  = getArraySafe(ueRxBytesBase, idxS);

    deltaB = max(0, (rxEndM - baseM) + (rxEndS - baseS));
    ueTputPhys(p) = deltaB * 8 / Tcurr / 1e6;
end

pTiles = [5 50 95];
q = myQuantile(ueTputPhys, pTiles);

cellUserCount = zeros(numCells,1);
for p = 1:numUEsPhysical
    c = ueServingCell(p);
    if c >= 1 && c <= numCells
        cellUserCount(c) = cellUserCount(c) + 1;
    end
end
cellLoadRatio = cellUserCount / max(1, numUEsPhysical);

BASE_DELAY_MACRO = 10.0; % ms
BASE_DELAY_SMALL = 5.0;  % ms

P_MACRO_ON    = 1.0;
P_SMALL_ON    = 0.5;
P_SMALL_SLEEP = 0.1;

cellDelayMs = zeros(numCells,1);
cellPower   = zeros(numCells,1);
cellEE      = zeros(numCells,1);

for c = 1:numCells
    rho = min(cellLoadRatio(c), 0.99);
    if c == 1
        baseDelay = BASE_DELAY_MACRO;
        cellPower(c) = P_MACRO_ON;
    else
        baseDelay = BASE_DELAY_SMALL;
        if cellActive(c)
            cellPower(c) = P_SMALL_ON;
        else
            cellPower(c) = P_SMALL_SLEEP;
        end
    end

    cellDelayMs(c) = baseDelay / (1 - rho);

    if cellPower(c) > 0
        cellEE(c) = cellTputMbps(c) / cellPower(c);
    else
        cellEE(c) = 0;
    end
end

estimatedEnergyW = sum(cellPower);

if numCells > 1
    numSmall = numCells - 1;
    numSleepSmall = 0;
    for c = 2:numCells
        if ~cellActive(c)
            numSleepSmall = numSleepSmall + 1;
        end
    end
    sleepRatioSmall = numSleepSmall / numSmall;
else
    sleepRatioSmall = 0;
end

numUEsPhys = numUEsPhysical;
ueDelayMs  = zeros(numUEsPhys,1);
ueEE       = zeros(numUEsPhys,1);

for p = 1:numUEsPhys
    c = ueServingCell(p);
    if c >= 1 && c <= numCells
        ueDelayMs(p) = cellDelayMs(c);
        if cellPower(c) > 0
            ueEE(p) = ueTputPhys(p) / cellPower(c);
        else
            ueEE(p) = 0;
        end
    else
        ueDelayMs(p) = 0;
        ueEE(p)      = 0;
    end
end

simKPI = struct();
simKPI.cellTputMbps     = cellTputMbps;
simKPI.totalTputMbps    = totalTputMbps;
simKPI.ueTputPhys       = ueTputPhys;
simKPI.ueTput5          = q(1);
simKPI.ueTput50         = q(2);
simKPI.ueTput95         = q(3);
simKPI.estimatedEnergyW = estimatedEnergyW;
simKPI.sleepRatioSmall  = sleepRatioSmall;

cellEntry = struct();
cellEntry.time_window_s      = [tStart, tEnd];
cellEntry.cell_id            = 1:numCells;
cellEntry.throughput_Mbps    = cellTputMbps(:)';
cellEntry.delay_ms           = cellDelayMs(:)';
cellEntry.load_ratio         = cellLoadRatio(:)';
cellEntry.power_norm         = cellPower(:)';
cellEntry.energyEff_MbpsPerPower = cellEE(:)';

ueEntry = struct();
ueEntry.time_window_s      = [tStart, tEnd];
ueEntry.ue_id              = 1:numUEsPhys;
ueEntry.serving_cell       = ueServingCell(:)';
ueEntry.traffic_type       = appType(:)';
ueEntry.throughput_Mbps    = ueTputPhys(:)';
ueEntry.delay_ms           = ueDelayMs(:)';
ueEntry.energyEff_MbpsPerPower = ueEE(:)';

end

%% ===== 小工具函数 =====

function v = getUEBytes(ueStats, idx)
if idx < 1 || idx > numel(ueStats)
    v = 0;
    return;
end
st = ueStats(idx);
if isfield(st,"MAC") && isfield(st.MAC,"ReceivedBytes")
    v = double(st.MAC.ReceivedBytes);
else
    v = 0;
end
end

function v = getArraySafe(arr, idx)
if idx < 1 || idx > numel(arr)
    v = 0;
else
    v = double(arr(idx));
end
end

function nearState = collectNearRTState(gNBs, ueServingCell, ueSmallCell, cellActive, appType)
numCells       = numel(gNBs);
[qL, LR] = computeBSLoadFeatures(ueServingCell, appType, numCells);

nearState = struct();
nearState.numCells      = numCells;
nearState.numUEs        = numel(ueServingCell);
nearState.ueServingCell = ueServingCell(:)';
nearState.ueSmallCell   = ueSmallCell(:)';
nearState.cellActive    = logical(cellActive(:))';
nearState.trafficType   = appType(:)';
nearState.useSmall      = (ueServingCell(:)' ~= 1);
nearState.qL            = qL;
nearState.LR            = LR;
end

function nonRTState = collectNonRTState(gNBs, ueServingCell, ueSmallCell, cellActive, appType)
numCells       = numel(gNBs);
[qL, LR] = computeBSLoadFeatures(ueServingCell, appType, numCells);

nonRTState = struct();
nonRTState.numCells      = numCells;
nonRTState.numUEs        = numel(ueServingCell);
nonRTState.ueServingCell = ueServingCell(:)';
nonRTState.ueSmallCell   = ueSmallCell(:)';
nonRTState.cellActive    = logical(cellActive(:))';
nonRTState.trafficType   = appType(:)';
nonRTState.qL            = qL;
nonRTState.LR            = LR;
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
                    % sleep -> active：其余留给 near-RT 决策
                end
            end

            new_cellActive = act;
        end
    end
end

cellActive = new_cellActive;
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
