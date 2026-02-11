function action = xapp_main(input)
%XAPP_TRAJECTORY_HANDOVER
% Simple mobility-aware handover assistant (MVP)

    obs = input.measurements;

    numCell = obs.numCell;

    % 默认不干预
    ho_offset = zeros(numCell,1);

    % 参数（MVP）
    v_th = 10;      % m/s，速度阈值
    offset_fast = -1.0;  % 高速 UE，提前切换
    offset_slow = 0.0;   % 低速 UE，不干预

    for c = 1:numCell

        ueSet = find(obs.servingCell == c);
        if isempty(ueSet)
            continue;
        end

        % 需要 ObsAdapter 提供 ueSpeed
        if ~isfield(obs, "ueSpeed")
            continue;
        end

        v = obs.ueSpeed(ueSet);
        avgV = mean(v);

        if avgV > v_th
            ho_offset(c) = offset_fast;
        else
            ho_offset(c) = offset_slow;
        end
    end

    action.control.handover_hysteresis_offset_dB = ho_offset;
    action.metadata.xapp = "xapp_trajectory_handover";
end
