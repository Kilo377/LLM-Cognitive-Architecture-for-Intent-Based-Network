function beamIdx = nearRT_beam_ric(state, numBeams)
% nearRT_beam_ric
% -------------------------------------------------------------------------
% Beam RIC 决策入口（供 RICBeamScheduler 使用）。
%
% 输入：
%   state.RNTIList  : 当前 slot 去重后的 RNTI 列表 (1 x numUEs)
%   state.numUEs    : 当前 slot UE 数
%   numBeams        : 码本大小
%
% 输出：
%   beamIdx         : [numUEs x 1] 的码本索引（1..numBeams）
%
% 策略选择依据：
%   全局变量：
%     - RIC_currentTime, RIC_policySwitchTime
%     - RIC_beamPolicyPrevID, RIC_beamPolicyCurrID
%
% 支持策略 ID（与 ric_policy_registry 保持一致）：
%   - "beam_default"      => 等价于 "beam_random"
%   - "beam_random"       => 每 UE 独立随机选束
%   - "beam_round_robin"  => 根据 RNTI 做 round-robin
%   - "beam_fixed_center" => 所有 UE 使用同一个中心束

    % ==== 解析 UE 数 ====
    if isfield(state, "numUEs")
        numUEs = state.numUEs;
    elseif isfield(state, "RNTIList")
        numUEs = numel(state.RNTIList);
    else
        numUEs = 0;
    end

    if numUEs == 0 || numBeams <= 0
        beamIdx = zeros(numUEs, 1);
        return;
    end

    % ==== 读取策略 ID ====
    global RIC_currentTime RIC_policySwitchTime
    global RIC_beamPolicyPrevID RIC_beamPolicyCurrID

    idPrev = "beam_default";
    idCurr = "beam_default";

    if ~isempty(RIC_beamPolicyPrevID)
        idPrev = string(RIC_beamPolicyPrevID);
    end
    if ~isempty(RIC_beamPolicyCurrID)
        idCurr = string(RIC_beamPolicyCurrID);
    else
        idCurr = idPrev;
    end

    if isempty(RIC_policySwitchTime) || isempty(RIC_currentTime)
        activePolicyId = idCurr;
    else
        if RIC_currentTime < RIC_policySwitchTime
            activePolicyId = idPrev;
        else
            activePolicyId = idCurr;
        end
    end

    % ==== 按策略 ID 分支 ====
    switch activePolicyId
        case "beam_default"
            beamIdx = beam_policy_random(state, numBeams);

        case "beam_random"
            beamIdx = beam_policy_random(state, numBeams);

        case "beam_round_robin"
            beamIdx = beam_policy_round_robin(state, numBeams);

        case "beam_fixed_center"
            beamIdx = beam_policy_fixed_center(state, numBeams);

        otherwise
            warning("nearRT_beam_ric: 未知 beam 策略 ID = %s，回退到随机束。", activePolicyId);
            beamIdx = beam_policy_random(state, numBeams);
    end
end

%% ====== Beam 策略实现 ======

function beamIdx = beam_policy_random(state, numBeams)
% 每个 UE 独立随机选择 [1..numBeams]

if isfield(state, "numUEs")
    numUEs = state.numUEs;
elseif isfield(state, "RNTIList")
    numUEs = numel(state.RNTIList);
else
    numUEs = 0;
end

if numUEs == 0 || numBeams <= 0
    beamIdx = zeros(numUEs,1);
    return;
end

beamIdx = randi(numBeams, numUEs, 1);
end

function beamIdx = beam_policy_round_robin(state, numBeams)
% 按 RNTI 做 round-robin，保证同一 UE 在时间上的波束更稳定

if isfield(state, "RNTIList")
    rntiList = double(state.RNTIList(:)');
    numUEs   = numel(rntiList);
elseif isfield(state, "numUEs")
    numUEs   = state.numUEs;
    rntiList = 1:numUEs;
else
    numUEs = 0;
    rntiList = [];
end

if numUEs == 0 || numBeams <= 0
    beamIdx = zeros(numUEs,1);
    return;
end

beamIdx = zeros(numUEs,1);
for i = 1:numUEs
    rnti = rntiList(i);
    idx  = mod(rnti-1, numBeams) + 1;   % 1..numBeams
    beamIdx(i) = idx;
end
end

function beamIdx = beam_policy_fixed_center(state, numBeams)
% 所有 UE 使用一个"中心"波束

if isfield(state, "numUEs")
    numUEs = state.numUEs;
elseif isfield(state, "RNTIList")
    numUEs = numel(state.RNTIList);
else
    numUEs = 0;
end

if numUEs == 0 || numBeams <= 0
    beamIdx = zeros(numUEs,1);
    return;
end

centerIdx = round((numBeams + 1) / 2);
centerIdx = max(1, min(numBeams, centerIdx));

beamIdx = repmat(centerIdx, numUEs, 1);
end
