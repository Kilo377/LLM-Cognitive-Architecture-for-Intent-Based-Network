function env = oranScenarioInit_light()
% oranScenarioInit_light
% 轻量版 5G NR 多小区场景初始化（支持"1 个物理 UE = 2 个逻辑 UE"双连接建模）
%
% - gNB: 1 宏 + 2 微
% - 物理 UE 数: numUEsPhysical = 5
%   * 对于每个物理 UE p：
%       - UE_p_M: 只挂宏小区 (gNB 1)，索引 macroUEIndices(p)
%       - UE_p_S: 只挂某个微小区 gNB (2..numCells)，索引 smallUEIndices(p)
%   * 两个 UE 位置相同，在统计和 RIC 决策层面当作一个 UE
% - 每个物理 UE 初始全部走宏小区流量：
%       宏 leg DataRate = 高速，微 leg DataRate = very low（近似关闭）
%
% - 注意：这里的 simulationTime 是"仿真器允许的最大时长"（例如 5 s），
%         具体跑多久由 oranSim_RL_step_light 里的 targetSimTime 决定。

%% 0) 支持包检查 & 初始化
wirelessnetworkSupportPackageCheck;
rng("default");

networkSimulator = wirelessNetworkSimulator.init;

% 给仿真器一个比较大的上限，比如 5 秒
simulationTime = 5.0;

%% 1) PHY / MIMO / MU-MIMO 配置
phyAbstractionType         = "linkToSystemMapping";
duplexType                 = "FDD";
csiMeasurementSignalDLType = "CSI-RS";

if csiMeasurementSignalDLType == "SRS"
    muMIMOConfiguration = struct( ...
        "MaxNumUsersPaired", 2, ...
        "MaxNumLayers",      8, ...
        "MinNumRBs",         2, ...
        "MinSINR",           10);
else
    muMIMOConfiguration = struct( ...
        "MaxNumUsersPaired", 2, ...
        "MaxNumLayers",      8, ...
        "MinNumRBs",         2);
end

allocationType = 0;  % RBG

tddConfig = struct( ...
    "DLULPeriodicity",5, ...
    "NumDLSlots",2, ...
    "NumDLSymbols",12, ...
    "NumULSymbols",1, ...
    "NumULSlots",2);

%% 2) 拓扑：1 宏 + 2 微
numMacro = 1;
numSmall = 2;
numCells = numMacro + numSmall;

macroPos    = [0 0 30];
macroRadius = 500;

smallAttachRadius = 200;
smallRad          = macroRadius - smallAttachRadius;  % 300m
smallHeight       = 10;

gNBPositions       = zeros(numCells,3);
gNBPositions(1,:)  = macroPos;
for i = 1:numSmall
    angle = 2*pi*(i-1)/numSmall;
    gNBPositions(1+i,:) = [smallRad*cos(angle), smallRad*sin(angle), smallHeight];
end
gNBNames = "gNB-" + (1:numCells);

numTxAntGNB = 16;
numRxAntGNB = 16;

%% 3) 创建 gNB
gNBs = nrGNB.empty;
for i = 1:numCells
    if i == 1
        carrierFreq = 3.5e9;
        txPow       = 43;
        chanBW      = 60e6;
    else
        carrierFreq = 30e9;
        txPow       = 38;
        chanBW      = 60e6;
    end

    gNBs(i) = nrGNB( ...
        "Name",                 gNBNames(i), ...
        "Position",             gNBPositions(i,:), ...
        "CarrierFrequency",     carrierFreq, ...
        "ChannelBandwidth",     chanBW, ...
        "SubcarrierSpacing",    30e3, ...
        "DuplexMode",           duplexType, ...
        "DLULConfigTDD",        tddConfig, ...
        "NumTransmitAntennas",  numTxAntGNB, ...
        "NumReceiveAntennas",   numRxAntGNB, ...
        "ReceiveGain",          11, ...
        "TransmitPower",        txPow, ...
        "PHYAbstractionMethod", phyAbstractionType, ...
        "SRSPeriodicityUE",     40);
end

for g = 1:numCells
    configureScheduler(gNBs(g), ...
        "ResourceAllocationType", allocationType, ...
        "MaxNumUsersPerTTI",      10, ...
        "MUMIMOConfigDL",         muMIMOConfiguration, ...
        "CSIMeasurementSignalDL", csiMeasurementSignalDLType);
end

%% 4) 物理 UE → 两个逻辑 UE（宏 leg + 微 leg）

numUEsPhysical = 5;                  % 物理 UE 数
numUEsNodes    = 2*numUEsPhysical;   % 实际 nrUE 节点数

ueHeight    = 1.5;
allUEPositionsPhysical = generateUEPositionsInMacro(macroRadius, macroPos, ueHeight, numUEsPhysical);

allUEs = nrUE.empty(numUEsNodes,0);

macroUEIndices = zeros(numUEsPhysical,1);
smallUEIndices = zeros(numUEsPhysical,1);
ueSmallCell    = zeros(numUEsPhysical,1);  % 每个物理 UE 对应的微小区 gNB 索引（2..numCells）

for p = 1:numUEsPhysical
    pos = allUEPositionsPhysical(p,:);

    idxMacro = 2*p-1;
    idxSmall = 2*p;

    macroUEIndices(p) = idxMacro;
    smallUEIndices(p) = idxSmall;

    % 宏 leg UE（只挂 gNB 1）
    allUEs(idxMacro) = nrUE( ...
        "Name",                "UE"+p+"_M", ...
        "Position",            pos, ...
        "NumTransmitAntennas", 4, ...
        "NumReceiveAntennas",  4, ...
        "ReceiveGain",         11, ...
        "PHYAbstractionMethod", phyAbstractionType);

    % 微 leg UE（挂最近的微小区 gNB）
    nearestSmall = RIC_selectNearestSmall(pos, gNBPositions);
    ueSmallCell(p) = nearestSmall;

    allUEs(idxSmall) = nrUE( ...
        "Name",                "UE"+p+"_S", ...
        "Position",            pos, ...
        "NumTransmitAntennas", 4, ...
        "NumReceiveAntennas",  4, ...
        "ReceiveGain",         11, ...
        "PHYAbstractionMethod", phyAbstractionType);
end

%% 5) 连接 UE（宏 leg → 宏 gNB，微 leg → 对应微 gNB）

rlcBearer = nrRLCBearerConfig("SNFieldLength",6,"BucketSizeDuration",10);

for p = 1:numUEsPhysical
    idxMacro = macroUEIndices(p);
    idxSmall = smallUEIndices(p);
    smallCellIdx = ueSmallCell(p);

    connectUE(gNBs(1), allUEs(idxMacro), ...
        "RLCBearerConfig",      rlcBearer, ...
        "CSIReportPeriodicity", 10);

    connectUE(gNBs(smallCellIdx), allUEs(idxSmall), ...
        "RLCBearerConfig",      rlcBearer, ...
        "CSIReportPeriodicity", 10);
end

%% 6) 配置业务类型 & 流量模型（全部用 OnOff，方便改 DataRate）

numVideo  = 2;
numGaming = 1;
numVoice  = 1;
numURLLC  = 1;
assert(numVideo + numGaming + numVoice + numURLLC == numUEsPhysical, ...
    "业务类型数量之和必须等于物理 UE 数");

appType = [ ...
    ones(numVideo,1); ...
    2*ones(numGaming,1); ...
    3*ones(numVoice,1); ...
    4*ones(numURLLC,1)];
appType = appType(randperm(numUEsPhysical));

% 高速 DataRate（kbps）
videoDataRateKbps  = 4000;  % 视频
gamingDataRateKbps = 1000;  % 游戏
voiceDataRateKbps  = 256;   % 语音，近似低码率流
urllcDataRateKbps  = 2000;  % URLLC
% "几乎关掉"的很低 DataRate
lowDataRateKbps    = 1;     % 1 kbps，相当于不怎么发

dlTrafficMacro = cell(numUEsPhysical,1);
dlTrafficSmall = cell(numUEsPhysical,1);

for p = 1:numUEsPhysical
    at = appType(p);

    switch at
        case 1  % Video
            highRate = videoDataRateKbps;
            macroTraffic = networkTrafficOnOff( ...
                "OnTime",         simulationTime, ...
                "OffTime",        0, ...
                "DataRate",       highRate, ...
                "PacketSize",     1400, ...
                "GeneratePacket", true);
            smallTraffic = networkTrafficOnOff( ...
                "OnTime",         simulationTime, ...
                "OffTime",        0, ...
                "DataRate",       lowDataRateKbps, ...
                "PacketSize",     1400, ...
                "GeneratePacket", true);

        case 2  % Gaming
            highRate = gamingDataRateKbps;
            macroTraffic = networkTrafficOnOff( ...
                "OnTime",         simulationTime, ...
                "OffTime",        0, ...
                "DataRate",       highRate, ...
                "PacketSize",     800, ...
                "GeneratePacket", true);
            smallTraffic = networkTrafficOnOff( ...
                "OnTime",         simulationTime, ...
                "OffTime",        0, ...
                "DataRate",       lowDataRateKbps, ...
                "PacketSize",     800, ...
                "GeneratePacket", true);

        case 3  % Voice（用低速 OnOff 近似）
            highRate = voiceDataRateKbps;
            macroTraffic = networkTrafficOnOff( ...
                "OnTime",         simulationTime, ...
                "OffTime",        0, ...
                "DataRate",       highRate, ...
                "PacketSize",     200, ...
                "GeneratePacket", true);
            smallTraffic = networkTrafficOnOff( ...
                "OnTime",         simulationTime, ...
                "OffTime",        0, ...
                "DataRate",       lowDataRateKbps, ...
                "PacketSize",     200, ...
                "GeneratePacket", true);

        case 4  % URLLC（高频小包 OnOff）
            highRate = urllcDataRateKbps;
            macroTraffic = networkTrafficOnOff( ...
                "OnExponentialMean",  1e-3, ...
                "OffExponentialMean", 1e-3, ...
                "DataRate",           highRate, ...
                "PacketSize",         100, ...
                "GeneratePacket",     true);
            smallTraffic = networkTrafficOnOff( ...
                "OnExponentialMean",  1e-3, ...
                "OffExponentialMean", 1e-3, ...
                "DataRate",           lowDataRateKbps, ...
                "PacketSize",         100, ...
                "GeneratePacket",     true);
    end

    dlTrafficMacro{p} = macroTraffic;
    dlTrafficSmall{p} = smallTraffic;

    idxMacro = macroUEIndices(p);
    idxSmall = smallUEIndices(p);

    addTrafficSource(gNBs(1), macroTraffic, "DestinationNode", allUEs(idxMacro));
    addTrafficSource(gNBs(ueSmallCell(p)), smallTraffic, "DestinationNode", allUEs(idxSmall));
end

%% 7) 加入网络模拟器 + 信道

addNodes(networkSimulator, gNBs);
addNodes(networkSimulator, allUEs);

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

%% 8) 初始 cellActive（全开）和 ueServingCell（全走宏）

cellActive    = true(numCells,1);
ueServingCell = ones(numUEsPhysical,1);   % 1 = 宏，2..numCells = 微（当前全 1）

%% 9) 打包 env

env = struct();
env.networkSimulator = networkSimulator;
env.simulationTime   = simulationTime;   % 上限

env.gNBs             = gNBs;
env.allUEs           = allUEs;
env.numUEsPhysical   = numUEsPhysical;
env.macroUEIndices   = macroUEIndices;
env.smallUEIndices   = smallUEIndices;
env.ueSmallCell      = ueSmallCell;

env.ueServingCell    = ueServingCell;
env.cellActive       = cellActive;
env.appType          = appType;

env.videoDataRateKbps  = videoDataRateKbps;
env.gamingDataRateKbps = gamingDataRateKbps;
env.voiceDataRateKbps  = voiceDataRateKbps;
env.urllcDataRateKbps  = urllcDataRateKbps;
env.lowDataRateKbps    = lowDataRateKbps;

env.dlTrafficMacro   = dlTrafficMacro;
env.dlTrafficSmall   = dlTrafficSmall;
env.rlcBearer        = rlcBearer;

end  % function oranScenarioInit_light

%% ===== 辅助函数 =====

function uePositions = generateUEPositionsInMacro(radius, centerPos, ueHeight, numUEs)
theta = rand(numUEs,1) * 2*pi;
r     = sqrt(rand(numUEs,1)) * radius;
x     = centerPos(1) + r .* cos(theta);
y     = centerPos(2) + r .* sin(theta);
z     = ones(numUEs,1) * ueHeight;
uePositions = [x y z];
end

function smallIdx = RIC_selectNearestSmall(uePos, gNBPositions)
% 在 gNBPositions(2:end,:) 里找与 uePos 最近的微小区索引
numCells = size(gNBPositions,1);
bestIdx  = 2;
bestDist = inf;
for c = 2:numCells
    d = norm(uePos(1:2) - gNBPositions(c,1:2));
    if d < bestDist
        bestDist = d;
        bestIdx  = c;
    end
end
smallIdx = bestIdx;
end
