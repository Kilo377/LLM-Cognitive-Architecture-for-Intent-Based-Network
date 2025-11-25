%% oranSim.m
% 多小区 NR 系统级仿真骨架（O-RAN 风格：1 宏 + 多微 + MIMO + MU-MIMO 调度）
% - 宏小区：3.5 GHz（Sub-6，广覆盖）
% - 微小区：30 GHz（mmWave，小范围高容量）
% - UE 在宏小区覆盖范围内随机分布
% - 单连接：每个 UE 只连一个 gNB（宏 or 某个微），后续由 RIC 决定"二选一"策略
% - 四类业务：Video / Gaming / Voice / URLLC

%% 0) 支持包检查 & 初始化
wirelessnetworkSupportPackageCheck;
rng("default");

numFrameSimulation = 500;              % 500 帧 = 5 秒（10 ms / frame）
simulationTime     = numFrameSimulation * 1e-2;  % 仿真总时长（秒）
networkSimulator   = wirelessNetworkSimulator.init;

%% 1) PHY / MIMO / MU-MIMO 配置
phyAbstractionType         = "linkToSystemMapping";   % 抽象 PHY（系统级建议）
duplexType                 = "FDD";                    % 可改成 TDD
csiMeasurementSignalDLType = "CSI-RS";                 % 也可以改成 "SRS"

% MU-MIMO 参数（MinSINR 只在 SRS 模式有意义）
if csiMeasurementSignalDLType == "SRS"
    muMIMOConfiguration = struct( ...
        MaxNumUsersPaired = 2, ...
        MaxNumLayers      = 8, ...
        MinNumRBs         = 2, ...
        MinSINR           = 10);      % SRS 模式下生效
else
    muMIMOConfiguration = struct( ...
        MaxNumUsersPaired = 2, ...
        MaxNumLayers      = 8, ...
        MinNumRBs         = 2);       % CSI-RS 模式不带 MinSINR，避免警告
end

allocationType = 0;  % 资源分配类型：0 = RBG

tddConfig = struct(DLULPeriodicity=5,NumDLSlots=2,NumDLSymbols=12,...
                   NumULSymbols=1,NumULSlots=2);    % 当前 FDD，TDD 配置暂不使用

%% 2) gNB 拓扑：1 宏 + 4 微
numMacro = 1;
numSmall = 4;
numCells = numMacro + numSmall;

macroPos    = [0 0 30];    % 宏站中心，高度 30 m
macroRadius = 500;         % 宏小区覆盖半径（仅用于画图和 UE 随机分布）

% 设计：宏小区覆盖所有微小区，且微小区间基本不重叠
smallAttachRadius = 200;                      % 微小区有效覆盖半径（用于关联 & 画圈）
smallRad          = macroRadius - smallAttachRadius;  % = 300 m，微小区中心到宏站距离
smallHeight       = 10;                       % 微小区 gNB 高度

gNBPositions = zeros(numCells,3);
gNBPositions(1,:) = macroPos;

% 4 个微小区围绕宏站均匀布置在半径 smallRad 的圆上
for i = 1:numSmall
    angle = 2*pi*(i-1)/numSmall;
    gNBPositions(1+i,:) = [smallRad*cos(angle), smallRad*sin(angle), smallHeight];
end

gNBOfInterestIdx = 1;                 % 关注的 gNB（宏小区）
gNBNames         = "gNB-" + (1:numCells);

% gNB 天线数
numTxAntGNB = 16;
numRxAntGNB = 16;

%% 3) 创建 gNB（宏 / 微不同频段 + 不同功率）
gNBs = nrGNB.empty;
for i = 1:numCells
    if i == 1
        % 宏小区：3.5 GHz, 功率 43 dBm
        carrierFreq = 3.5e9;
        txPow       = 43;
        chanBW      = 60e6;   % 60 MHz
    else
        % 微小区：30 GHz mmWave, 功率 38 dBm
        carrierFreq = 30e9;
        txPow       = 38;
        chanBW      = 60e6;   % 60 MHz
    end

    gNBs(i) = nrGNB( ...
        Name                 = gNBNames(i), ...
        Position             = gNBPositions(i,:), ...
        CarrierFrequency     = carrierFreq, ...
        ChannelBandwidth     = chanBW, ...
        SubcarrierSpacing    = 30e3, ...          % 60 MHz 对应 30k/60k，选 30k
        DuplexMode           = duplexType, ...
        DLULConfigTDD        = tddConfig, ...
        NumTransmitAntennas  = numTxAntGNB, ...
        NumReceiveAntennas   = numRxAntGNB, ...
        ReceiveGain          = 11, ...
        TransmitPower        = txPow, ...
        PHYAbstractionMethod = phyAbstractionType, ...
        SRSPeriodicityUE     = 40);
end

% 调度器配置：启用 MU-MIMO 能力
for g = 1:numCells
    configureScheduler(gNBs(g), ...
        ResourceAllocationType   = allocationType, ...
        MaxNumUsersPerTTI        = 10, ...
        MUMIMOConfigDL           = muMIMOConfiguration, ...
        CSIMeasurementSignalDL   = csiMeasurementSignalDLType);
end

%% 4) UE 随机分布在宏小区覆盖范围内，然后"二选一"关联到宏 or 微（为后续 RIC 留接口）

numUEsTotal = 60;                     % 总 UE 数
ueHeight    = 1.5;

% 4.1 在宏小区内随机生成 UE 位置
allUEPositions = generateUEPositionsInMacro(macroRadius, macroPos, ueHeight, numUEsTotal);

% 4.2 创建全局 UE 对象（先不区分 cell）
allUEs = nrUE.empty;
for ueIdx = 1:numUEsTotal
    ueName = "UE-" + ueIdx;
    allUEs(ueIdx) = nrUE( ...
        Name                 = ueName, ...
        Position             = allUEPositions(ueIdx,:), ...
        NumTransmitAntennas  = 4, ...
        NumReceiveAntennas   = 4, ...
        ReceiveGain          = 11, ...
        PHYAbstractionMethod = phyAbstractionType);
end

% 4.3 "单连接 + RIC 接口"：为每个 UE 选择一个服务小区
% 当前策略：如果在某个微小区半径 smallAttachRadius 内，则优先连最近微小区，否则连宏小区

ueServingCell = zeros(numUEsTotal,1);   % ueServingCell(ueIdx) = gNB index
for ueIdx = 1:numUEsTotal
    uePos = allUEPositions(ueIdx,:);
    ueServingCell(ueIdx) = RIC_selectServingCell(uePos, gNBPositions, smallAttachRadius);
end

% 4.4 按小区整理 UEs{cellIdx}
UEs = cell(numCells,1);
ueIndicesInCell = cell(numCells,1);

for cellIdx = 1:numCells
    ueIdxList = find(ueServingCell == cellIdx);
    ueIndicesInCell{cellIdx} = ueIdxList;
    UEs{cellIdx} = allUEs(ueIdxList);
end

%% 4.x 拓扑可视化（宏 + 微 + UE 分布）

figure; hold on; grid on; axis equal;
title("5G 多小区拓扑（宏 + 微 + UE 关联）");
xlabel("X (m)");
ylabel("Y (m)");

% 1) 画宏小区覆盖边界
theta = linspace(0, 2*pi, 360);
macroCircleX = macroPos(1) + macroRadius * cos(theta);
macroCircleY = macroPos(2) + macroRadius * sin(theta);
plot(macroCircleX, macroCircleY, 'k--', 'LineWidth', 1.2); % 宏小区边界

% 2) 画各个 gNB 位置
% 宏 gNB
plot(macroPos(1), macroPos(2), 'rs', 'MarkerSize', 10, 'LineWidth', 2, ...
    'DisplayName', '宏 gNB (3.5 GHz)');

% 微 gNB
plot(gNBPositions(2:end,1), gNBPositions(2:end,2), 'b^', 'MarkerSize', 8, ...
    'LineWidth', 1.5, 'DisplayName', '微 gNB (30 GHz)');

% 给每个 gNB 标个名字
for i = 1:numCells
    text(gNBPositions(i,1)+5, gNBPositions(i,2)+5, gNBNames(i), ...
        'FontSize', 8, 'Color', 'k');
end

% 3) 画每个微小区的"有效覆盖半径"圆（smallAttachRadius）
for i = 2:numCells
    smallCircleX = gNBPositions(i,1) + smallAttachRadius * cos(theta);
    smallCircleY = gNBPositions(i,2) + smallAttachRadius * sin(theta);
    plot(smallCircleX, smallCircleY, ':', 'Color', [0.3 0.3 1], 'LineWidth', 1);
end

% 4) 画 UE，并按关联小区着色
colors = lines(numCells); % 每个小区一个颜色
for ueIdx = 1:numUEsTotal
    cIdx = ueServingCell(ueIdx);           % 该 UE 关联的小区 index
    xy   = allUEPositions(ueIdx,1:2);
    plot(xy(1), xy(2), 'o', ...
        'MarkerSize', 4, ...
        'MarkerFaceColor', colors(cIdx,:), ...
        'MarkerEdgeColor', colors(cIdx,:));
end

% 再单独画一个图例用的"虚拟点"（只为 legend 好看）
hMacroUE = plot(NaN, NaN, 'o', 'MarkerSize', 5, ...
    'MarkerFaceColor', colors(1,:), 'MarkerEdgeColor', colors(1,:));
hSmallUE = plot(NaN, NaN, 'o', 'MarkerSize', 5, ...
    'MarkerFaceColor', colors(2,:), 'MarkerEdgeColor', colors(2,:));

legend([...
    findobj(gca,'DisplayName','宏 gNB (3.5 GHz)'), ...
    findobj(gca,'DisplayName','微 gNB (30 GHz)'), ...
    hMacroUE, hSmallUE], ...
    {'宏 gNB (3.5 GHz)', '微 gNB (30 GHz)', ...
     '宏小区服务的 UE', '微小区服务的 UE'}, ...
    'Location', 'bestoutside');

% 视图范围稍微放大一点，看着更舒服
xlim([macroPos(1) - macroRadius*1.1, macroPos(1) + macroRadius*1.1]);
ylim([macroPos(2) - macroRadius*1.1, macroPos(2) + macroRadius*1.1]);

hold off;

%% 5) 连接 UE & RLC 配置（这里不再用 FullBufferTraffic）
rlcBearer = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);

for cellIdx = 1:numCells
    if isempty(UEs{cellIdx})
        continue;
    end
    connectUE(gNBs(cellIdx), UEs{cellIdx}, ...
        RLCBearerConfig      = rlcBearer, ...
        CSIReportPeriodicity = 10);
end

%% 6) 配置四类业务流量：Video / Gaming / Voice / URLLC（下行为主）

% 论文中的业务说明（Inter-arrival 只是统计特性，我们用不同 traffic model 近似）：
% - Video:   平均 12.5 ms，Pareto（我们用高码率、On-Off burst 模型近似）
% - Gaming:  平均 40 ms，Uniform（用较低、接近周期的 On-Off 模型近似）
% - Voice:   平均 20 ms，Poisson（用 networkTrafficVoIP 近似）
% - URLLC:   平均 0.5 ms，Poisson（用高速、小包 On-Off + 随机 On/Off 近似）

% 按比例分配业务类型（可根据需求改）
numVideo  = 20;
numGaming = 15;
numVoice  = 15;
numURLLC  = 10;
assert(numVideo + numGaming + numVoice + numURLLC == numUEsTotal, ...
    "业务类型数量之和必须等于 UE 总数");

appType = [ ...
    ones(numVideo,1); ...
    2*ones(numGaming,1); ...
    3*ones(numVoice,1); ...
    4*ones(numURLLC,1)];
appType = appType(randperm(numUEsTotal));   % 打乱分配给 UE

% 视频业务参数（Video）
videoDataRateKbps = 4000;    % 约 4 Mbps
videoPktSizeBytes = 1400;

% 游戏业务参数（Gaming）
gamingDataRateKbps = 1000;   % 1 Mbps
gamingPktSizeBytes = 800;

% URLLC 业务参数
urllcDataRateKbps  = 2000;   % 2 Mbps
urllcPktSizeBytes  = 100;    % 小包

for cellIdx = 1:numCells
    ueIdxList = ueIndicesInCell{cellIdx};
    if isempty(ueIdxList)
        continue;
    end

    for k = 1:numel(ueIdxList)
        globalUEid = ueIdxList(k);
        ueObj      = allUEs(globalUEid);

        switch appType(globalUEid)
            case 1   % Video - 近似为持续高码率流（OnTime=仿真全程）
                dlTraffic = networkTrafficOnOff( ...
                    OnTime        = simulationTime, ...
                    OffTime       = 0, ...
                    DataRate      = videoDataRateKbps, ...   % kbps
                    PacketSize    = videoPktSizeBytes, ...
                    GeneratePacket= true);

            case 2   % Gaming - 中等速率，相对"平滑"的流
                dlTraffic = networkTrafficOnOff( ...
                    OnTime        = simulationTime, ...
                    OffTime       = 0, ...
                    DataRate      = gamingDataRateKbps, ...
                    PacketSize    = gamingPktSizeBytes, ...
                    GeneratePacket= true);

            case 3   % Voice - 使用 VoIP traffic 模型（带随机性）
                dlTraffic = networkTrafficVoIP( ...
                    ExponentialMean = 20, ...  % 调整活跃/静音平均时长（单位：ms）
                    HasJitter       = true, ...
                    GeneratePacket  = true);

            case 4   % URLLC - 高频小包，使用随机 On-Off 近似 Poisson
                dlTraffic = networkTrafficOnOff( ...
                    OnExponentialMean  = 1e-3, ...  % 平均 On 时长 1 ms
                    OffExponentialMean = 1e-3, ...  % 平均 Off 时长 1 ms
                    DataRate      = urllcDataRateKbps, ...
                    PacketSize    = urllcPktSizeBytes, ...
                    GeneratePacket= true);
        end

        % 下行业务：从 gNB -> UE
        addTrafficSource(gNBs(cellIdx), dlTraffic, DestinationNode=ueObj);

        % 如果你后续想加上行：可以在这里再给 UE 装一个 traffic，默认目的地为连接的 gNB
        % ulTraffic = dlTraffic;   % 简单对称
        % addTrafficSource(ueObj, ulTraffic);
    end
end

%% 7) 加入网络模拟器
addNodes(networkSimulator, gNBs);
for cellIdx = 1:numCells
    if ~isempty(UEs{cellIdx})
        addNodes(networkSimulator, UEs{cellIdx});
    end
end

%% 8) 3GPP 38.901 UMa 信道模型（所有链路统一，用中心频率区分 pathloss）
posGNB = reshape([gNBs.Position],3,[]);
posUE  = reshape([allUEs.Position],3,[]);
posAll = [posGNB posUE];

minX = min(posAll(1,:));
minY = min(posAll(2,:));
width  = max(posAll(1,:)) - minX;
height = max(posAll(2,:)) - minY;

channel = h38901Channel(Scenario="UMa",ScenarioExtents=[minX minY width height]);
addChannelModel(networkSimulator,@channel.channelFunction);
connectNodes(channel,networkSimulator);

%% 9) Trace & KPI 可视化（不再用 helperNetworkVisualizer，避免 hold 错误）
enableTraces         = true;
linkDir              = 0;      % 0 = DL
numMetricPlotUpdates = 20;

if enableTraces
    simSchedulingLogger = cell(numCells,1);
    simPhyLogger        = cell(numCells,1);
    for cellIdx = 1:numCells
        if isempty(UEs{cellIdx})
            continue;
        end
        simSchedulingLogger{cellIdx} = helperNRSchedulingLogger( ...
            numFrameSimulation, gNBs(cellIdx), UEs{cellIdx}, LinkDirection=linkDir);
        simPhyLogger{cellIdx}        = helperNRPhyLogger( ...
            numFrameSimulation, gNBs(cellIdx), UEs{cellIdx});
    end
end

metricsVisualizer = helperNRMetricsVisualizer( ...
    gNBs(gNBOfInterestIdx), UEs{gNBOfInterestIdx}, ...
    CellOfInterest       = gNBs(gNBOfInterestIdx).ID, ...
    RefreshRate          = numMetricPlotUpdates, ...
    PlotSchedulerMetrics = true, ...
    PlotPhyMetrics       = true, ...
    PlotCDFMetrics       = true, ...
    LinkDirection        = linkDir);

% ⚠ 不再创建 helperNetworkVisualizer，避免 hold 在删除坐标轴上的错误
% networkVisualizer = helperNetworkVisualizer(SampleRate=5);
% showBoundaries(networkVisualizer, gNBPositions, macroRadius, gNBOfInterestIdx);

%% 10) 运行仿真
fprintf("开始仿真：%.2f 秒...\n", simulationTime);
run(networkSimulator, simulationTime);
fprintf("仿真结束。\n");

%% 11) KPI 输出
gNBStats = statistics(gNBs);
ueStats  = cell(numCells,1);
for cellIdx = 1:numCells
    if isempty(UEs{cellIdx})
        ueStats{cellIdx} = [];
    else
        ueStats{cellIdx} = statistics(UEs{cellIdx});
    end
end
displayPerformanceIndicators(metricsVisualizer);

%% 12) 保存日志
simulationLogFile = "oranSimulationLogs_MultiCell_MUMIMO";
if enableTraces
    simulationLogs = cell(numCells,1);
    for cellIdx = 1:numCells
        if isempty(UEs{cellIdx})
            continue;
        end

        if gNBs(cellIdx).DuplexMode == "FDD"
            logInfo = struct(NCellID=[],DLTimeStepLogs=[],ULTimeStepLogs=[],...
                             SchedulingAssignmentLogs=[],PhyReceptionLogs=[]);
            [logInfo.DLTimeStepLogs,logInfo.ULTimeStepLogs] = ...
                getSchedulingLogs(simSchedulingLogger{cellIdx});
        else
            logInfo = struct(NCellID=[],TimeStepLogs=[],...
                             SchedulingAssignmentLogs=[],PhyReceptionLogs=[]);
            logInfo.TimeStepLogs = getSchedulingLogs(simSchedulingLogger{cellIdx});
        end
        logInfo.NCellID                  = gNBs(cellIdx).ID;
        logInfo.SchedulingAssignmentLogs = getGrantLogs(simSchedulingLogger{cellIdx});
        logInfo.PhyReceptionLogs         = getReceptionLogs(simPhyLogger{cellIdx});
        simulationLogs{cellIdx}          = logInfo;
    end
    save(simulationLogFile,"simulationLogs","gNBStats","ueStats");
    fprintf("仿真日志已保存到 %s.mat\n", simulationLogFile);
end

%% =============== 本文件用到的本地函数 ===============

function uePositions = generateUEPositionsInMacro(radius, centerPos, ueHeight, numUEs)
% 在给定圆形区域（宏小区）内均匀随机生成 UE 位置
theta = rand(numUEs,1) * 2*pi;
r     = sqrt(rand(numUEs,1)) * radius;
x     = centerPos(1) + r .* cos(theta);
y     = centerPos(2) + r .* sin(theta);
z     = ones(numUEs,1) * ueHeight;
uePositions = [x y z];
end

function servingCell = RIC_selectServingCell(uePos, gNBPositions, smallAttachRadius)
% RIC_selectServingCell
% 当前策略：
%   - 如果 UE 在某个微小区 smallAttachRadius 内，则连最近微小区
%   - 否则连宏小区（索引 1）
%
% 后续可以在这里加入：负载、业务类型、RL / DQN 决策等逻辑

numCells = size(gNBPositions,1);

% 默认连宏小区
servingCell = 1;

% 搜索最近微小区
bestSmallIdx = -1;
bestDist     = inf;

for cellIdx = 2:numCells   % 微小区从 2 开始
    d = norm(uePos(1:2) - gNBPositions(cellIdx,1:2));
    if d < bestDist
        bestDist     = d;
        bestSmallIdx = cellIdx;
    end
end

if bestDist < smallAttachRadius
    servingCell = bestSmallIdx;
end
end
