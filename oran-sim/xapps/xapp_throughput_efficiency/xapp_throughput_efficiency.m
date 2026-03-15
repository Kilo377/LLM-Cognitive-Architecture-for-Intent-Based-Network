function action = xapp_throughput_efficiency(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;

    action = struct();

    meanBLER = 0;
    dropRatio = 0;
    p50 = 0;

    if isfield(obs,'kpi')
        if isfield(obs.kpi,'reliability')
            if isfield(obs.kpi.reliability,'meanBLER')
                meanBLER = double(obs.kpi.reliability.meanBLER);
            end
            if isfield(obs.kpi.reliability,'dropRatio')
                dropRatio = double(obs.kpi.reliability.dropRatio);
            end
        end
        if isfield(obs.kpi,'phy') && isfield(obs.kpi.phy,'p50SINR_dB')
            p50 = double(obs.kpi.phy.p50SINR_dB);
        end
    end

    trigger = false;
    if meanBLER > 0.008 || dropRatio > 0.06
        trigger = true;
    end
    if p50 < 12
        trigger = true;
    end

    if ~trigger
        return;
    end

    prbUtil = zeros(numCell,1);
    if isfield(obs,'cell') && isfield(obs.cell,'prbUtil')
        prbUtil = double(obs.cell.prbUtil(:));
    elseif isfield(obs,'kpi') && isfield(obs.kpi,'resource') && isfield(obs.kpi.resource,'prbUtilMean')
        prbUtil = double(obs.kpi.resource.prbUtilMean) * ones(numCell,1);
    end
    if numel(prbUtil) ~= numCell
        prbUtil = zeros(numCell,1);
    end
    prbUtil = min(max(prbUtil,0),1);

    txTarget = zeros(numCell,1);
    if p50 < 8
        txTarget = 2 * ones(numCell,1);
    elseif meanBLER > 0.015
        txTarget = -1 * ones(numCell,1);
    else
        txTarget = -0.5 * prbUtil;
    end
    txTarget = min(max(txTarget,-2.0),3.0);

    action.beam.mode = "adaptive";
    action.radio.txPowerOffset_dB = txTarget(:);
end
