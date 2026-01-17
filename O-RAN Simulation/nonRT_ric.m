function [cellActiveAction, reward, info] = nonRT_ric(state)
% MATLAB 版 non-RT RIC (Cell Sleeping, 带滞回 + 探索)
% 输入：
%   state.numCells
%   state.numUEs
%   state.ueServingCell   (当前 UE 实际服务小区)
%   state.ueSmallCell     (每个 UE 对应的小小区索引)
%   state.cellActive      (当前各小区开/关)
%   state.trafficType     (每个 UE 业务类型 1..4)
%   （可选）state.useSmall：当前 UE 是否走小小区（如果没有，就用 ueServing!=1）
%
% 输出：
%   cellActiveAction(numCells x 1 logical)：non-RT 这一步决定的小区开关动作
%   reward：以能量效率为主的启发式 reward
%   info：   附加 KPI 信息，方便分析和离线 RL 用

numCells    = state.numCells;
numUEs      = state.numUEs;
ueSmallCell = state.ueSmallCell(:);
ueServing   = state.ueServingCell(:);
cellActive0 = logical(state.cellActive(:));  % 当前（上一时刻）小区状态
trafficType = state.trafficType(:);

% 如果 state 里已有 useSmall，则用它；否则根据 ueServing 是否为宏推断
if isfield(state, "useSmall")
    useSmallVec = logical(state.useSmall(:));
else
    useSmallVec = (ueServing ~= 1);
end

%% ===== 参数定义（可根据仿真效果微调） =====

% 业务权重（和 near-RT 保持一致）
TRAFFIC_WEIGHT = containers.Map( ...
    {'1','2','3','4'}, ...
    [3.0, 2.0, 1.0, 4.0]);  % 1:Video,2:Gaming,3:Voice,4:URLLC

BASE_RATE_MACRO  = 1.0;
BASE_RATE_SMALL  = 3.0;

P_MACRO_ON    = 1.0;
P_SMALL_ON    = 0.5;
P_SMALL_SLEEP = 0.1;

OVERLOAD_TH      = 0.7;
OVERLOAD_PENALTY = 0.2;   % EE 里对过载小区的惩罚

% 滞回相关门限：避免频繁开关
MACRO_LIGHT_TH   = 0.30;  % 宏负载小于此值时，适合多睡小小区
MACRO_MODERATE_TH= 0.60;  % 中等负载
MACRO_HEAVY_TH   = 0.80;  % 宏负载较高：倾向于多开小小区

% 探索概率（对每个小小区独立 ε-greedy 翻转）
EPS_EXPLORATION  = 0.10;  % 10%

%% ===== 统计当前基于 ueServing 的负载 =====

cellLoad = zeros(numCells,1);
for k = 1:numel(ueServing)
    c = ueServing(k);
    if c>=1 && c<=numCells
        cellLoad(c) = cellLoad(c) + 1;
    end
end

macroLoad = cellLoad(1) / max(1,numUEs);

% 每个小小区的"潜在" UE 数（所有 ueSmallCell==c）
potentialSmallLoad = zeros(numCells,1);
for k = 1:numel(ueSmallCell)
    c = ueSmallCell(k);
    if c>=2 && c<=numCells
        potentialSmallLoad(c) = potentialSmallLoad(c)+1;
    end
end

%% ===== 基于启发式 + 滞回 的 cellActiveAction =====

% 初始：从当前状态出发（有"惯性"），再在此基础上修改
cellActiveAction = cellActive0;
cellActiveAction(1) = true;  % 宏小区始终 ON

if macroLoad < MACRO_LIGHT_TH
    % 宏非常轻载：可以大胆关掉多数小小区，只保留潜在负载最高的 1 个（如果有）
    % 先关掉所有小小区
    for c = 2:numCells
        cellActiveAction(c) = false;
    end

    % 找潜在负载最大的小小区
    [maxLoad, bestC] = max(potentialSmallLoad(2:end));
    bestC = bestC + 1;  % offset 因为索引从 2 开始

    if maxLoad > 0
        cellActiveAction(bestC) = true;
    end

elseif macroLoad < MACRO_MODERATE_TH
    % 宏中等负载：开一部分小小区（前 K 个潜在负载大的），其余睡掉
    K = 1;  % 你可以多试几个值，比如 1 或 2

    candidates = [];
    for c = 2:numCells
        candidates = [candidates; potentialSmallLoad(c), c]; %#ok<AGROW>
    end
    if ~isempty(candidates)
        candidates = sortrows(candidates, -1);  % 按潜在负载降序
    end

    % 先全部关掉
    for c = 2:numCells
        cellActiveAction(c) = false;
    end

    for idx = 1:min(K,size(candidates,1))
        loadC = candidates(idx,1);
        c     = candidates(idx,2);
        if loadC > 0
            cellActiveAction(c) = true;
        end
    end

else
    % 宏负载较高：尽量把有潜在 UE 的小小区都打开，帮忙分担
    for c = 2:numCells
        if potentialSmallLoad(c) > 0
            cellActiveAction(c) = true;
        else
            % 没有潜在 UE 的小小区可以睡掉节能
            cellActiveAction(c) = false;
        end
    end
end

cellActiveAction(1) = true;

%% ===== ε-greedy 探索：对小小区随机翻转开关 =====

for c = 2:numCells
    if rand < EPS_EXPLORATION
        cellActiveAction(c) = ~cellActiveAction(c);
    end
end
% 再次确保宏 ON
cellActiveAction(1) = true;

%% ===== 计算 reward：以 EE 为主（和你 log 里的定义保持一致） =====

% 使用当前 ueServing + useSmallVec 估算 throughput
cellLoad2 = zeros(numCells,1);
for k = 1:numel(ueServing)
    c = ueServing(k);
    if c>=1 && c<=numCells
        cellLoad2(c) = cellLoad2(c)+1;
    end
end

cellLoadRatio = cellLoad2 / max(1,numUEs);

totalT      = 0.0;
cellTput    = zeros(numCells,1);

for p = 1:numUEs
    t  = trafficType(p);
    key = num2str(t);
    if isKey(TRAFFIC_WEIGHT,key)
        w = TRAFFIC_WEIGHT(key);
    else
        w = 1.0;
    end

    % 根据 useSmallVec 判断 UE 用宏还是小小区
    if useSmallVec(p) && ueSmallCell(p) >= 2 && ueSmallCell(p) <= numCells
        baseRate = BASE_RATE_SMALL;
        c = ueSmallCell(p);
    else
        baseRate = BASE_RATE_MACRO;
        c = 1;
    end

    loadC = max(1, cellLoad2(c));
    rate  = baseRate * w / loadC;

    totalT      = totalT + rate;
    cellTput(c) = cellTput(c) + rate;
end

% 小区功耗
cellPower = zeros(numCells,1);
cellPower(1) = P_MACRO_ON;
for c = 2:numCells
    if cellActiveAction(c)
        cellPower(c) = P_SMALL_ON;
    else
        cellPower(c) = P_SMALL_SLEEP;
    end
end
totalPower = sum(cellPower);

if totalPower <= 0
    EE = 0.0;
else
    EE = totalT / totalPower;
end

% 只对当前"活着"的小区做 overload 惩罚
overloadCells = 0;
for c = 1:numCells
    if ~cellActiveAction(c)
        continue;
    end
    if cellLoadRatio(c) > OVERLOAD_TH
        overloadCells = overloadCells + 1;
    end
end

reward = EE - OVERLOAD_PENALTY * overloadCells;

%% ===== info 结构，方便离线 RL / 分析 =====

info = struct();
info.cellThroughput   = cellTput';
info.totalThroughput  = totalT;
info.cellPower        = cellPower';
info.totalPower       = totalPower;
info.energyEfficiency = EE;
info.cellLoadRatio    = cellLoadRatio';
info.overloadCells    = overloadCells;
info.cellActiveAction = logical(cellActiveAction(:))';

end
