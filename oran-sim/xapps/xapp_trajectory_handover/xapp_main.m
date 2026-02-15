function action = xapp_main(input)
%XAPP_TRAJECTORY_HANDOVER
% Mobility-aware handover optimization xApp
%
% 功能：
%  - 根据小区内高速 UE 占比调整 HO hysteresis
%  - 高速比例高 → 减小 hysteresis → 提前切换
%  - 低速为主 → 不干预
%
% 输出：
%  action.handover.hysteresis_offset_dB

    obs = input.measurements;

    numCell = obs.numCell;

    %% ===== 默认不干预 =====
    ho_offset = zeros(numCell,1);

    %% ===== 参数（可后续做成 policy）=====
    v_th = 10;          % 高速阈值 m/s
    ratio_th = 0.3;     % 高速 UE 占比阈值
    offset_fast = -2.0; % 强化效果，便于验证
    offset_slow = 0.0;

    if ~isfield(obs,"ueSpeed")
        action = struct();
        return;
    end

    for c = 1:numCell

        ueSet = find(obs.servingCell == c);
        if isempty(ueSet)
            continue;
        end

        v = obs.ueSpeed(ueSet);

        % 计算高速 UE 占比
        highRatio = sum(v > v_th) / numel(v);

        if highRatio > ratio_th
            ho_offset(c) = offset_fast;
        else
            ho_offset(c) = offset_slow;
        end
    end

    %% ===== 输出到 handover 模块 =====
    action = struct();
    action.handover.hysteresisOffset_dB = ho_offset;

    action.metadata.xapp = "xapp_trajectory_handover";
end
