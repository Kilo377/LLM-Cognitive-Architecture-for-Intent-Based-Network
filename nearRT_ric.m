function [useSmall, reward] = nearRT_ric(state)
% MATLAB 版 near-RT RIC (Traffic Steering)
% 输入：
%   state.numCells, numUEs, ueServingCell, ueSmallCell,
%   cellActive, trafficType
% 输出：
%   useSmall(numUEs×1 double 0/1)
%   reward   (启发式估计)

numCells     = state.numCells;
numUEs       = state.numUEs;
ueServing    = state.ueServingCell(:);
ueSmallCell  = state.ueSmallCell(:);
cellActive   = logical(state.cellActive(:));
trafficType  = state.trafficType(:);

% 与 Python nearRT_ric.py 中一致的参数
TRAFFIC_WEIGHT = containers.Map( ...
    {'1','2','3','4'}, ...
    [3.0, 2.0, 1.0, 4.0]);   % 1:Video,2:Gaming,3:Voice,4:URLLC

BASE_RATE_MACRO   = 1.0;
BASE_RATE_SMALL   = 3.0;
OVERLOAD_TH       = 0.6;
OVERLOAD_PENALTY  = 10.0;

%% ===== heuristic_traffic_steering =====

% 当前每个小区负载（基于 ueServingCell）
cellLoad = zeros(numCells+1,1); % 用 1..numCells 索引
for k = 1:numel(ueServing)
    c = ueServing(k);
    if c>=1 && c<=numCells
        cellLoad(c) = cellLoad(c) + 1;
    end
end

macroLoad = cellLoad(1) / max(1,numUEs);

% 小小区负载
smallLoad = zeros(numCells+1,1);
for c = 2:numCells
    smallLoad(c) = cellLoad(c) / max(1,numUEs);
end

useSmall = zeros(numUEs,1);   % 默认全走宏

for p = 1:numUEs
    t = trafficType(p);
    smallC = ueSmallCell(p);

    wantSmall = false;

    if smallC >= 2 && smallC <= numCells && cellActive(smallC)
        isHighBW = (t == 1) || (t == 4); % Video/URLLC
        isMidBW  = (t == 2);             % Gaming

        % 条件：宏负载>0.6 且目标小小区负载<0.5
        if macroLoad > 0.6 && smallLoad(smallC) < 0.5
            if isHighBW || isMidBW
                wantSmall = true;
            end
        end
    end

    useSmall(p) = double(wantSmall);
end

%% ===== estimate_throughput + reward =====

% 先使用动作 useSmall 计算新的 cell 负载
cellLoadAct = zeros(numCells+1,1);
for p = 1:numUEs
    if useSmall(p) && cellActive(ueSmallCell(p))
        c = ueSmallCell(p);
    else
        c = 1;
    end
    if c>=1 && c<=numCells
        cellLoadAct(c) = cellLoadAct(c)+1;
    end
end

totalT = 0.0;
for p = 1:numUEs
    t  = trafficType(p);
    key = num2str(t);
    if isKey(TRAFFIC_WEIGHT,key)
        w = TRAFFIC_WEIGHT(key);
    else
        w = 1.0;
    end

    if useSmall(p) && cellActive(ueSmallCell(p))
        baseRate = BASE_RATE_SMALL;
        c = ueSmallCell(p);
    else
        baseRate = BASE_RATE_MACRO;
        c = 1;
    end

    loadC = max(1, cellLoadAct(c));
    rate  = baseRate * w / loadC;
    totalT = totalT + rate;
end

% 过载惩罚
overloadCells = 0;
for c = 1:numCells
    loadRatio = cellLoadAct(c) / max(1,numUEs);
    if loadRatio > OVERLOAD_TH
        overloadCells = overloadCells + 1;
    end
end

reward = totalT - OVERLOAD_PENALTY * overloadCells;

end
