function action = xapp_main(input)
%XAPP_FAIR_SCHEDULER
% Fair scheduler based on buffer backlog + channel quality

    obs = input.measurements;

    numCell = obs.numCell;
    numUE   = obs.numUE;

    sel = zeros(numCell,1);

    for c = 1:numCell

        ueSet = find(obs.servingCell == c);
        if isempty(ueSet)
            continue;
        end

        % 只调度有数据的 UE
        if isfield(obs,'buffer_bits')
            hasData = obs.buffer_bits(ueSet) > 0;
            ueSet = ueSet(hasData);
            if isempty(ueSet)
                continue;
            end
        end

        sinr = obs.sinr_dB(ueSet);

        % 速率近似
        rateEst = log2(1 + 10.^(sinr/10));

        % backlog 权重
        if isfield(obs,'buffer_bits')
            backlog = obs.buffer_bits(ueSet);
        else
            backlog = ones(size(ueSet));
        end

        % Normalize backlog
        if max(backlog) > 0
            backlogNorm = backlog / max(backlog);
        else
            backlogNorm = backlog;
        end

        % Fair score
        score = backlogNorm .* rateEst;

        [~, idx] = max(score);
        u = ueSet(idx);

        sel(c) = u;
    end

    action.control.selectedUE = sel;
    action.metadata.xapp = "xapp_fair_scheduler";
end
