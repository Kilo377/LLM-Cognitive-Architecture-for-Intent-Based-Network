function [useSmall, reward, info] = nearRT_ric(state)
% MATLAB 版 near-RT RIC (Traffic Steering, 带滞回 + 随机探索)
%
% 输入 state：
%   state.numCells, numUEs
%   state.ueServingCell, ueSmallCell
%   state.cellActive
%   state.trafficType
%   state.qL, state.LR
%   （可选）state.useSmall：上一时刻是否走小小区
%
% 输出：
%   useSmall(numUEs×1 double 0/1)
%   reward   启发式 reward
%   info     记录一些 KPI 指标

numCells     = state.numCells;
numUEs       = state.numUEs;
ueServing    = state.ueServingCell(:);
ueSmallCell  = state.ueSmallCell(:);
cellActive   = logical(state.cellActive(:));
trafficType  = state.trafficType(:);

% 当前 per-cell 负载比例（如果 state 里已经传了 LR，就直接用）
if isfield(state,"LR")
    LR = state.LR(:);
else
    LR = zeros(numCells,1);
    for c = 1:numCells
        LR(c) = sum(ueServing == c) / max(1,numUEs);
    end
end

% 上一时刻 useSmall（如果没有就默认全 0）
if isfield(state,"useSmall")
    prevUseSmall = logical(state.useSmall(:));
else
    prevUseSmall = false(numUEs,1);
end

%% ===== 启发式 Traffic Steering（带滞回 + 探索） =====

macroLoad = LR(1);
smallLoad = LR;
if numCells >= 1
    smallLoad(1) = 0;   % 忽略宏
end

useSmall = zeros(numUEs,1);  % 默认全走宏（0）

% 滞回门限（可以以后根据仿真调参）
MACRO_HIGH_TH      = 0.70;  % 宏很忙：考虑 offload
MACRO_LOW_TH       = 0.40;  % 宏很闲：考虑回收一些
SMALL_LOW_TH       = 0.40;  % 小小区很闲：适合 offload
SMALL_HIGH_TH      = 0.80;  % 小小区很忙：考虑拉回宏
MACRO_RECOVER_TH   = 0.60;  % 回收时要求宏负载不能太高

% ε-greedy 探索概率（适当小一点，避免太乱）
EPS_EXPLORATION    = 0.10;  % 10%

for p = 1:numUEs
    t = trafficType(p);
    smallC = ueSmallCell(p);

    % 默认：沿用上一时刻动作（有"惯性"）
    wantSmall = prevUseSmall(p);

    % 如果该 UE 没有有效小小区或小小区处于 sleep，则强制走宏
    if ~(smallC >= 2 && smallC <= numCells && cellActive(smallC))
        wantSmall = false;
        useSmall(p) = double(wantSmall);
        continue;
    end

    smallLoadC = smallLoad(smallC);

    % 业务类型分类
    isHighBW = (t == 1) || (t == 4); % Video/URLLC
    isMidBW  = (t == 2);             % Gaming
    isLowBW  = (t == 3);             % Voice

    % === 逻辑 1：当前在宏（prevUseSmall=0）时，什么时候下小小区？ ===
    if ~prevUseSmall(p)
        % 宏比较忙、小小区比较闲，高/中带宽业务才会被 offload
        if macroLoad > MACRO_HIGH_TH && smallLoadC < SMALL_LOW_TH && (isHighBW || isMidBW)
            wantSmall = true;
        else
            wantSmall = false;  % 否则保持在宏
        end
    else
        % === 逻辑 2：当前在小小区（prevUseSmall=1）时，什么时候回宏？ ===
        % 只有当小小区非常拥塞，且宏负载没有特别高时，才考虑回落
        if smallLoadC > SMALL_HIGH_TH && macroLoad < MACRO_RECOVER_TH
            wantSmall = false;
        else
            % 否则保持在小小区，不来回抖
            wantSmall = true;
        end
    end

    % === 逻辑 3：低带宽业务（Voice）更"保守"一些 ===
    if isLowBW
        % 低带宽业务一般不太依赖小小区性能，略微偏向"保持当前状态"
        wantSmall = prevUseSmall(p);
    end

    % === 逻辑 4：ε-greedy 探索，偶尔反向一下决策 ===
    if rand < EPS_EXPLORATION
        wantSmall = ~wantSmall;
    end

    % 再次保证：不能把 UE 放到 sleep 小小区
    if ~(smallC >= 2 && smallC <= numCells && cellActive(smallC))
        wantSmall = false;
    end

    useSmall(p) = double(wantSmall);
end

%% ===== 估算吞吐 & 时延 & reward（和之前版本保持一致） =====

% 业务权重（和 qL、一致）
getWeight = @(t) ...
    (t==1) * 3.0 + ...  % Video
    (t==2) * 2.0 + ...  % Gaming
    (t==3) * 1.0 + ...  % Voice
    (t==4) * 4.0 + ...  % URLLC
    (~ismember(t,[1 2 3 4])) * 1.0;

BASE_RATE_MACRO = 1.0;
BASE_RATE_SMALL = 3.0;

BASE_DELAY_MACRO = 10.0; % ms
BASE_DELAY_SMALL = 5.0;  % ms

OVERLOAD_TH       = 0.80;
THROUGHPUT_WEIGHT = 1.0;
DELAY_WEIGHT      = 0.1;
OVERLOAD_PENALTY  = 5.0;

% 1) 根据 useSmall + cellActive 重新统计每小区 UE 数
cellUserCount = zeros(numCells,1);
for p = 1:numUEs
    if useSmall(p) && ueSmallCell(p) >= 2 && ueSmallCell(p) <= numCells && cellActive(ueSmallCell(p))
        c = ueSmallCell(p);
    else
        c = 1;
    end
    cellUserCount(c) = cellUserCount(c) + 1;
end

cellLoadRatioAct = cellUserCount / max(1,numUEs);

% 2) per-UE throughput
totalT  = 0.0;
cellTput = zeros(numCells,1);
for p = 1:numUEs
    t = trafficType(p);
    w = getWeight(t);

    if useSmall(p) && ueSmallCell(p) >= 2 && ueSmallCell(p) <= numCells && cellActive(ueSmallCell(p))
        baseRate = BASE_RATE_SMALL;
        c = ueSmallCell(p);
    else
        baseRate = BASE_RATE_MACRO;
        c = 1;
    end

    loadC = max(1, cellUserCount(c));
    rate  = baseRate * w / loadC;
    totalT = totalT + rate;
    cellTput(c) = cellTput(c) + rate;
end

avgThroughputPerUE = totalT / max(1,numUEs);

% 3) per-cell 时延估计（M/M/1 型）
cellDelay = zeros(numCells,1);
for c = 1:numCells
    rho = cellLoadRatioAct(c);
    rho = min(rho, 0.99);  % 避免除 0
    if c == 1
        baseDelay = BASE_DELAY_MACRO;
    else
        baseDelay = BASE_DELAY_SMALL;
    end
    cellDelay(c) = baseDelay / (1 - rho);
end

if numUEs > 0
    avgDelay = sum(cellDelay .* (cellUserCount / numUEs));
else
    avgDelay = 0.0;
end

% 4) 过载小区数（只看 active 小区）
overloadCells = sum((cellLoadRatioAct > OVERLOAD_TH) & cellActive(:));

% 5) 最终 reward
reward = THROUGHPUT_WEIGHT * avgThroughputPerUE ...
       - DELAY_WEIGHT      * avgDelay ...
       - OVERLOAD_PENALTY  * overloadCells;

% info 供离线 RL / 分析用
info = struct();
info.cellLoadRatio       = cellLoadRatioAct';
info.cellUserCount       = cellUserCount';
info.cellThroughput      = cellTput';
info.totalThroughput     = totalT;
info.avgThroughputPerUE  = avgThroughputPerUE;
info.cellDelay           = cellDelay';
info.avgDelay            = avgDelay;
info.overloadCells       = overloadCells;

end
