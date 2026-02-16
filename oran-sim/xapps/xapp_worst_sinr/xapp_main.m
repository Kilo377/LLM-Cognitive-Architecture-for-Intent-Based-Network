function action = xapp_main(input)
%XAPP_WORST_SINR
% Force scheduler to always pick worst SINR UE

    obs = input.measurements;

    numCell = obs.numCell;
    sel = zeros(numCell,1);

    for c = 1:numCell

        ueSet = find(obs.servingCell == c);
        if isempty(ueSet)
            continue;
        end

        sinr = obs.sinr_dB(ueSet);

        % pick WORST
        [~, idx] = min(sinr);
        sel(c) = ueSet(idx);
    end

    action.scheduling.selectedUE = sel;
    action.metadata.xapp = "xapp_worst_sinr";
    %disp("[xapp_worst_sinr] selectedUE = ")
    %disp(sel(:).')

end
