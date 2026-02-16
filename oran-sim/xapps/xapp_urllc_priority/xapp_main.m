function action = xapp_main(input)
%XAPP_URLLC_PRIORITY v2
% Strongly prioritize UE with most urgent URLLC packets per cell

    obs = input.measurements;

    numCell = obs.numCell;

    sel = zeros(numCell,1);

    for c = 1:numCell

        ueSet = find(obs.servingCell == c);
        if isempty(ueSet)
            continue;
        end

        % urgent packets count
        urg = obs.urgent_pkts(ueSet);

        % if all zero, skip
        if all(urg == 0)
            continue;
        end

        % choose max urgent
        [~, idx] = max(urg);
        sel(c) = ueSet(idx);
    end

    % IMPORTANT: use correct field path
    action.scheduling.selectedUE = sel;

    action.metadata.xapp = "xapp_urllc_priority_v2";
end
