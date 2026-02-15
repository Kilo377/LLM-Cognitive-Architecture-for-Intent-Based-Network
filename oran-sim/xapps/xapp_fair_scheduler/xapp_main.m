function action = xapp_main(input)
%XAPP_FAIR_SCHEDULER
% Fairness-oriented scheduler
%
% 策略：
%   每个小区选择 buffer 最大的 UE
%
% 冲突目标：
%   与 xapp_throughput_scheduler 在 selectedUE 上冲突
%
% 输出：
%   action.scheduling.selectedUE (cell-level)

    obs = input.measurements;

    numCell = obs.numCell;

    % 默认不干预
    sel = zeros(numCell,1);

    % 必须有 buffer 信息
    if ~isfield(obs, "buffer_bits")
        action = struct();
        action.scheduling.selectedUE = sel;
        action.metadata.xapp = "xapp_fair_scheduler";
        return;
    end

    for c = 1:numCell

        % 当前小区 UE 集合
        ueSet = find(obs.servingCell == c);
        if isempty(ueSet)
            continue;
        end

        % 取 buffer
        buf = obs.buffer_bits(ueSet);

        % 如果全部为 0，则不干预
        if all(buf == 0)
            continue;
        end

        % 选择 buffer 最大的 UE
        [~, idx] = max(buf);
        u = ueSet(idx);

        sel(c) = u;
    end

    % 输出到 scheduling 模块
    action = struct();
    action.scheduling.selectedUE = sel;
    action.metadata.xapp = "xapp_fair_scheduler";
end
