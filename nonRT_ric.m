function [cellActiveAction, reward] = nonRT_ric(state)
% MATLAB 版 non-RT RIC (Cell Sleeping)
% 输入：
%   state.numCells, numUEs, ueServingCell, ueSmallCell,
%   cellActive, trafficType, useSmall(可有可无)
% 输出：
%   cellActiveAction(numCells×1 logical)
%   reward   (启发式 EE 近似)

numCells    = state.numCells;
numUEs      = state.numUEs;
ueSmallCell = state.ueSmallCell(:);
ueServing   = state.ueServingCell(:);
cellActiveCurrent = logical(state.cellActive(:));
trafficType = state.trafficType(:);

% 与 nonRT_ric.py 一致的参数
TRAFFIC_WEIGHT = containers.Map( ...
    {'1','2','3','4'}, ...
    [3.0, 2.0, 1.0, 4.0]);

BASE_RATE_MACRO  = 1.0;
BASE_RATE_SMALL  = 3.0;

P_MACRO_ON    = 1.0;
P_SMALL_ON    = 0.5;
P_SMALL_SLEEP = 0.1;

OVERLOAD_TH      = 0.7;
OVERLOAD_PENALTY = 0.2;

%% ===== heuristic_cell_sleeping =====

% 当前基于 ueServing 的负载
cellLoad = zeros(numCells+1,1);
for k = 1:numel(ueServing)
    c = ueServing(k);
    if c>=1 && c<=numCells
        cellLoad(c) = cellLoad(c)+1;
    end
end

macroLoad = cellLoad(1) / max(1,numUEs);

% 每个小小区的"潜在"UE 数（所有 ueSmallCell==c）
potentialSmallLoad = zeros(numCells+1,1);
for k = 1:numel(ueSmallCell)
    c = ueSmallCell(k);
    if c>=2 && c<=numCells
        potentialSmallLoad(c) = potentialSmallLoad(c)+1;
    end
end

% 初始：宏永远 ON，其余先全 ON
cellActiveAction = true(numCells,1);
cellActiveAction(1) = true;

if macroLoad < 0.4
    % 宏负载很低 -> 关掉所有小小区
    for c = 2:numCells
        cellActiveAction(c) = false;
    end

elseif macroLoad < 0.7
    % 中等负载 -> 开潜在 UE 数最多的前 K 个小小区
    candidates = [];
    for c = 2:numCells
        candidates = [candidates; potentialSmallLoad(c), c]; %#ok<AGROW>
    end
    if ~isempty(candidates)
        candidates = sortrows(candidates, -1);  % 第一列降序
    end
    K = 1;
    for idx = 1:size(candidates,1)
        loadC = candidates(idx,1);
        c     = candidates(idx,2);
        if idx <= K && loadC > 0
            cellActiveAction(c) = true;
        else
            cellActiveAction(c) = false;
        end
    end

else
    % 宏负载很高 -> 所有有潜在 UE 的小区开，否则关
    for c = 2:numCells
        if potentialSmallLoad(c) > 0
            cellActiveAction(c) = true;
        else
            cellActiveAction(c) = false;
        end
    end
end
cellActiveAction(1) = true;   % 宏强制 ON

%% ===== compute_reward （T/P_total - overload penalty） =====

% 默认 useSmallVec：根据 ueServing 是否 !=1
useSmallVec = (ueServing(:) ~= 1);

% 重新统计 cellLoadBasedOnServing
cellLoad2 = zeros(numCells+1,1);
for k = 1:numel(ueServing)
    c = ueServing(k);
    if c>=1 && c<=numCells
        cellLoad2(c) = cellLoad2(c)+1;
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

    if useSmallVec(p) && cellActiveCurrent(ueSmallCell(p))
        baseRate = BASE_RATE_SMALL;
        c = ueSmallCell(p);
    else
        baseRate = BASE_RATE_MACRO;
        c = 1;
    end

    loadC = max(1, cellLoad2(c));
    rate  = baseRate * w / loadC;
    totalT = totalT + rate;
end

% 功耗
P_total = P_MACRO_ON;
for c = 2:numCells
    if cellActiveAction(c)
        P_total = P_total + P_SMALL_ON;
    else
        P_total = P_total + P_SMALL_SLEEP;
    end
end

EE = totalT / max(P_total,1e-6);

% 过载惩罚：只看 active 的 cell
overloadCells = 0;
for c = 1:numCells
    if ~cellActiveAction(c)
        continue;
    end
    loadRatio = cellLoad2(c) / max(1,numUEs);
    if loadRatio > OVERLOAD_TH
        overloadCells = overloadCells + 1;
    end
end

reward = EE - OVERLOAD_PENALTY * overloadCells;

end
