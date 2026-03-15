function action = xapp_interference_mitigation(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;

    action = struct();

    dropRatio = 0;
    meanBLER = 0;
    p50 = 0;
    p90 = 0;

    if isfield(obs,'kpi') && isfield(obs.kpi,'reliability')
        if isfield(obs.kpi.reliability,'dropRatio')
            dropRatio = double(obs.kpi.reliability.dropRatio);
        end
        if isfield(obs.kpi.reliability,'meanBLER')
            meanBLER = double(obs.kpi.reliability.meanBLER);
        end
    end

    if isfield(obs,'kpi') && isfield(obs.kpi,'phy')
        if isfield(obs.kpi.phy,'p50SINR_dB')
            p50 = double(obs.kpi.phy.p50SINR_dB);
        end
        if isfield(obs.kpi.phy,'p90SINR_dB')
            p90 = double(obs.kpi.phy.p90SINR_dB);
        end
    end

    if ~(p50 > 1 && p90 > 4 && (meanBLER > 0.006 || dropRatio > 0.06))
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

    txTarget = -1.0 - 4.0 * prbUtil;
    txTarget = min(max(txTarget,-6.0),0.0);

    action.radio.txPowerOffset_dB = txTarget(:);
    action.beam.mode = "static";
end
