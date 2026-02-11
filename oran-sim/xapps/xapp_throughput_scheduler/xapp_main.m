function action = xapp_main(input)
%XAPP_THROUGHPUT_SCHEDULER
% Select UE with highest SINR per cell

    obs = input.measurements;
    numCell = obs.numCell;

    sel = zeros(numCell,1);

    for c = 1:numCell

        ueSet = find(obs.servingCell == c);
        if isempty(ueSet)
            continue;
        end

        sinr = obs.sinr_dB(ueSet);

        [~, idx] = max(sinr);
        u = ueSet(idx);

        sel(c) = u;
    end

    action.control.selectedUE = sel;
    action.metadata.xapp = "xapp_throughput_scheduler";
end
