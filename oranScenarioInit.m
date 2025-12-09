function env = oranScenarioInit()
% oranScenarioInit.m
% 负责：
%   - 搭建多小区 5G 场景（1 宏 + 4 微）
%   - 配置 PHY / MIMO / 流量 / 信道
%   - 创建 networkSimulator / gNB / UE / Metrics 可视化器
%
% 返回 env 结构体，供 oranSim_RL_step 使用

%% 0) 支持包检查 & 初始化
wirelessnetworkSupportPackageCheck;
rng("default");

numFrameSimulation = 500;              % 500 帧 = 5 秒（10 ms / frame）
simulationTime     = numFrameSimulation * 1e-2;  % 仿真总时长（秒）= 5
networkSimulator   = wirelessNetworkSimulator.init;

%% 1) PHY / MIMO / MU-MIMO 配置
phyAbstractionType         = "linkToSystemMapping";   % 抽象 PHY
duplexType                 = "FDD";                   % 可改成 TDD
csiMeasurementSignalDLType = "CSI-RS";                % 也可以改成 "SRS"

% MU-MIMO 参数（MinSINR 只在 SRS 模式有意义）
if csiMeasurementSignalDLType == "SRS"
    muMIMOConfiguration = struct( ...
        'MaxNumUsersPaired', 2, ...
        'MaxNumLayers',      8, ...
        'MinNumRBs',         2, ...
        'MinSINR',           10);
else
    muMIMOConfiguration = struct( ...
        'MaxNumUsersPaired', 2, ...    % Toolbox 要求 >=2
        'MaxNumLayers',      8, ...
        'MinNumRBs',         2);
end

allocationType = 0;  % 资源分配类型：0 = RBG

tddConfig = struct('DLULPeriodicity',5,'NumDLSlots',2,'NumDLSymbols',12, ...
                   'NumULSymbols',1,'NumULSlots',2);    % 当前 FDD，TDD 配置暂不使用

%% 2) gNB 拓扑：1 宏 + 4 微
numMacro = 1;
numSmall = 4;
numCells = numMacro + numSmall;

macroPos    = [0 0 30];    % 宏站中心，高度 30 m
macroRadius = 500;         % 宏小区覆盖半径

% 设计：宏小区覆盖所有微小区，且微小区间基本不重叠
smallAttachRadius = 200;                      % 微小区有效覆盖半径
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
numTxAntMacro = 16;
numTxAntSmall = 32;   % 允许的值：1,2,4,8,16,32
numRxAntGNB   = 16;

%% 3) gNB 创建 + 初始功率 / 小区状态
gNBTxPowerdBm = zeros(numCells,1);
gNBTxPowerdBm(1)     = 43; % 宏小区：3.5 GHz, 功率 43 dBm
gNBTxPowerdBm(2:end) = 38; % 微小区：30 GHz, 功率 38 dBm

cellActive = true(numCells,1);  % true = ON, false = sleeping（逻辑标志）

gNBs = nrGNB.empty;
for i = 1:numCells
    if i == 1
        carrierFreq = 3.5e9;
        chanBW      = 60e6;   % 60 MHz
        numTxAnt    = numTxAntMacro;
    else
        carrierFreq = 30e9;
        chanBW      = 60e6;   % 60 MHz
        numTxAnt    = numTxAntSmall;
    end

    gNBs(i) = nrGNB( ...
        'Name',                 gNBNames(i), ...
        'Position',             gNBPositions(i,:), ...
        'CarrierFrequency',     carrierFreq, ...
        'ChannelBandwidth',     chanBW, ...
        'SubcarrierSpacing',    30e3, ...
        'DuplexMode',           duplexType, ...
        'DLULConfigTDD',        tddConfig, ...
        'NumTransmitAntennas',  numTxAnt, ...
        'NumReceiveAntennas',   numRxAntGNB, ...
        'ReceiveGain',          11, ...
        'TransmitPower',        gNBTxPowerdBm(i), ...
        'PHYAbstractionMethod', phyAbstractionType, ...
        'SRSPeriodicityUE',     40);
end

% 调度器配置：
% - 宏小区：允许 MU-MIMO，每个 TTI 最多调度 10 个 UE
% - 微小区：仍然用同样 MU-MIMO 配置，但 MaxNumUsersPerTTI=1（一次只服务一个 UE）
for g = 1:numCells

    thisMUMIMO = muMIMOConfiguration;  % 不再改 MaxNumUsersPaired

    if g == 1
        maxUsersPerTTI = 10;  % 宏站：多用户
    else
        maxUsersPerTTI = 1;   % 微站：一次一个 UE，近似模拟波束成形
    end

    configureScheduler(gNBs(g), ...
        'ResourceAllocationType', allocationType, ...
        'MaxNumUsersPerTTI',      maxUsersPerTTI, ...
        'MUMIMOConfigDL',         thisMUMIMO, ...
        'CSIMeasurementSignalDL', csiMeasurementSignalDLType);
end

%% 4) UE 随机分布 + 初始小区选择

numUEsTotal = 60;                     % 总 UE 数
ueHeight    = 1.5;

% 4.1 在宏小区内随机生成 UE 位置
allUEPositions = generateUEPositionsInMacro(macroRadius, macroPos, ueHeight, numUEsTotal);

% 4.2 创建全局 UE 对象
allUEs = nrUE.empty;
for ueIdx = 1:numUEsTotal
    ueName = "UE-" + ueIdx;
    allUEs(ueIdx) = nrUE( ...
        'Name',                 ueName, ...
        'Position',             allUEPositions(ueIdx,:), ...
        'NumTransmitAntennas',  4, ...
        'NumReceiveAntennas',   4, ...
        'ReceiveGain',          11, ...
        'PHYAbstractionMethod', phyAbstractionType);
end

% 4.3 初始小区选择（简单几何策略）
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
xlabel("X (m)"); ylabel("Y (m)");

theta = linspace(0, 2*pi, 360);
macroCircleX = macroPos(1) + macroRadius * cos(theta);
macroCircleY = macroPos(2) + macroRadius * sin(theta);
plot(macroCircleX, macroCircleY, 'k--', 'LineWidth', 1.2); % 宏小区边界

plot(macroPos(1), macroPos(2), 'rs', 'MarkerSize', 10, 'LineWidth', 2, ...
    'DisplayName', '宏 gNB (3.5 GHz)');
plot(gNBPositions(2:end,1), gNBPositions(2:end,2), 'b^', 'MarkerSize', 8, ...
    'LineWidth', 1.5, 'DisplayName', '微 gNB (30 GHz)');

for i = 1:numCells
    text(gNBPositions(i,1)+5, gNBPositions(i,2)+5, gNBNames(i), ...
        'FontSize', 8, 'Color', 'k');
end

for i = 2:numCells
    smallCircleX = gNBPositions(i,1) + smallAttachRadius * cos(theta);
    smallCircleY = gNBPositions(i,2) + smallAttachRadius * sin(theta);
    plot(smallCircleX, smallCircleY, ':', 'Color', [0.3 0.3 1], 'LineWidth', 1);
end

colors = lines(numCells);
for ueIdx = 1:numUEsTotal
    cIdx = ueServingCell(ueIdx);
    xy   = allUEPositions(ueIdx,1:2);
    plot(xy(1), xy(2), 'o', ...
        'MarkerSize', 4, ...
        'MarkerFaceColor', colors(cIdx,:), ...
        'MarkerEdgeColor', colors(cIdx,:));
end

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

xlim([macroPos(1) - macroRadius*1.1, macroPos(1) + macroRadius*1.1]);
ylim([macroPos(2) - macroRadius*1.1, macroPos(2) + macroRadius*1.1]);
hold off;

%% 5) 连接 UE & RLC 配置
rlcBearer = nrRLCBearerConfig('SNFieldLength',6,'BucketSizeDuration',10);

for cellIdx = 1:numCells
    if isempty(UEs{cellIdx})
        continue;
    end
    connectUE(gNBs(cellIdx), UEs{cellIdx}, ...
        'RLCBearerConfig',      rlcBearer, ...
        'CSIReportPeriodicity', 10);
end

%% 6) 配置四类业务流量（Video / Gaming / Voice / URLLC）

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
appType = appType(randperm(numUEsTotal));

videoDataRateKbps  = 4000;    % 约 4 Mbps
videoPktSizeBytes  = 1400;
gamingDataRateKbps = 1000;    % 1 Mbps
gamingPktSizeBytes = 800;
urllcDataRateKbps  = 2000;    % 2 Mbps
urllcPktSizeBytes  = 100;     % 小包

for cellIdx = 1:numCells
    ueIdxList = ueIndicesInCell{cellIdx};
    if isempty(ueIdxList)
        continue;
    end

    for k = 1:numel(ueIdxList)
        globalUEid = ueIdxList(k);
        ueObj      = allUEs(globalUEid);

        switch appType(globalUEid)
            case 1
                dlTraffic = networkTrafficOnOff( ...
                    'OnTime',        simulationTime, ...
                    'OffTime',       0, ...
                    'DataRate',      videoDataRateKbps, ...
                    'PacketSize',    videoPktSizeBytes, ...
                    'GeneratePacket', true);
            case 2
                dlTraffic = networkTrafficOnOff( ...
                    'OnTime',        simulationTime, ...
                    'OffTime',       0, ...
                    'DataRate',      gamingDataRateKbps, ...
                    'PacketSize',    gamingPktSizeBytes, ...
                    'GeneratePacket', true);
            case 3
                dlTraffic = networkTrafficVoIP( ...
                    'ExponentialMean', 20, ...
                    'HasJitter',       true, ...
                    'GeneratePacket',  true);
            case 4
                dlTraffic = networkTrafficOnOff( ...
                    'OnExponentialMean',  1e-3, ...
                    'OffExponentialMean', 1e-3, ...
                    'DataRate',           urllcDataRateKbps, ...
                    'PacketSize',         urllcPktSizeBytes, ...
                    'GeneratePacket',     true);
        end

        addTrafficSource(gNBs(cellIdx), dlTraffic, 'DestinationNode', ueObj);
    end
end

%% 7) 加入网络模拟器
addNodes(networkSimulator, gNBs);
for cellIdx = 1:numCells
    if ~isempty(UEs{cellIdx})
        addNodes(networkSimulator, UEs{cellIdx});
    end
end

%% 8) 信道模型
posGNB = reshape([gNBs.Position],3,[]);
posUE  = reshape([allUEs.Position],3,[]);
posAll = [posGNB posUE];

minX = min(posAll(1,:));
minY = min(posAll(2,:));
width  = max(posAll(1,:)) - minX;
height = max(posAll(2,:)) - minY;

channel = h38901Channel('Scenario',"UMa",'ScenarioExtents',[minX minY width height]);
addChannelModel(networkSimulator,@channel.channelFunction);
connectNodes(channel,networkSimulator);

%% 9) Trace & KPI 可视化（只做宏小区，可视化用）
enableTraces         = true;
linkDir              = 0;
numMetricPlotUpdates = 20;

simSchedulingLogger = cell(numCells,1);
simPhyLogger        = cell(numCells,1);
if enableTraces
    for cellIdx = 1:numCells
        if isempty(UEs{cellIdx})
            continue;
        end
        simSchedulingLogger{cellIdx} = helperNRSchedulingLogger( ...
            numFrameSimulation, gNBs(cellIdx), UEs{cellIdx}, 'LinkDirection', linkDir);
        simPhyLogger{cellIdx}        = helperNRPhyLogger( ...
            numFrameSimulation, gNBs(cellIdx), UEs{cellIdx});
    end
end

metricsVisualizer = helperNRMetricsVisualizer( ...
    gNBs(gNBOfInterestIdx), UEs{gNBOfInterestIdx}, ...
    'CellOfInterest',       gNBs(gNBOfInterestIdx).ID, ...
    'RefreshRate',          numMetricPlotUpdates, ...
    'PlotSchedulerMetrics', true, ...
    'PlotPhyMetrics',       true, ...
    'PlotCDFMetrics',       true, ...
    'LinkDirection',        linkDir);

%% 打包到 env 结构体，给外部使用
env = struct();
env.networkSimulator   = networkSimulator;
env.simulationTime     = simulationTime;
env.numFrameSimulation = numFrameSimulation;

env.gNBs           = gNBs;
env.allUEs         = allUEs;
env.ueServingCell  = ueServingCell;
env.cellActive     = cellActive;
env.appType        = appType;
env.metricsVisualizer = metricsVisualizer;

% 下面这些目前没用，但你以后扩展可能会用
env.enableTraces        = enableTraces;
env.simSchedulingLogger = simSchedulingLogger;
env.simPhyLogger        = simPhyLogger;
env.gNBOfInterestIdx    = gNBOfInterestIdx;

end  % function oranScenarioInit


%% ==== 本文件内部小工具函数 ====

function uePositions = generateUEPositionsInMacro(radius, centerPos, ueHeight, numUEs)
theta = rand(numUEs,1) * 2*pi;
r     = sqrt(rand(numUEs,1)) * radius;
x     = centerPos(1) + r .* cos(theta);
y     = centerPos(2) + r .* sin(theta);
z     = ones(numUEs,1) * ueHeight;
uePositions = [x y z];
end

function servingCell = RIC_selectServingCell(uePos, gNBPositions, smallAttachRadius)
numCells = size(gNBPositions,1);
servingCell = 1;
bestSmallIdx = -1;
bestDist     = inf;
for cellIdx = 2:numCells
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
