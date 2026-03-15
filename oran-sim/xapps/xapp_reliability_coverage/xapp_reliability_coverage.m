function action = xapp_reliability_coverage(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;
    numUE   = obs.topology.numUE;

    action = struct();

    persistent lastRlfCount initDone
    if isempty(initDone)
        lastRlfCount = 0;
        initDone = true;
    end

    servingCell = ones(numUE,1);
    sinr_dB = zeros(numUE,1);

    if isfield(obs,'ue')
        if isfield(obs.ue,'servingCell')
            servingCell = obs.ue.servingCell(:);
        end
        if isfield(obs.ue,'sinr_dB')
            sinr_dB = double(obs.ue.sinr_dB(:));
        end
    end

    dropRatio = 0;
    meanBLER = 0;
    rlfCount = 0;
    p10Global = 0;

    if isfield(obs,'kpi') && isfield(obs.kpi,'reliability')
        if isfield(obs.kpi.reliability,'dropRatio')
            dropRatio = double(obs.kpi.reliability.dropRatio);
        end
        if isfield(obs.kpi.reliability,'meanBLER')
            meanBLER = double(obs.kpi.reliability.meanBLER);
        end
        if isfield(obs.kpi.reliability,'rlfCount')
            rlfCount = double(obs.kpi.reliability.rlfCount);
        end
    end

    if isfield(obs,'kpi') && isfield(obs.kpi,'phy') && isfield(obs.kpi.phy,'p10SINR_dB')
        p10Global = double(obs.kpi.phy.p10SINR_dB);
    end

    rlfDelta = rlfCount - lastRlfCount;
    lastRlfCount = rlfCount;

    trigger = false;
    if p10Global < 5
        trigger = true;
    end
    if dropRatio > 0.05 || meanBLER > 0.01
        trigger = true;
    end
    if rlfDelta > 0
        trigger = true;
    end

    if ~trigger
        return;
    end

    txTarget = zeros(numCell,1);
    for c = 1:numCell
        ueIdx = find(servingCell == c);
        if isempty(ueIdx)
            continue;
        end
        p10 = prctile(sinr_dB(ueIdx),10);
        if p10 < -3
            txTarget(c) = 10;
        elseif p10 < 0
            txTarget(c) = 8;
        elseif p10 < 2
            txTarget(c) = 6;
        elseif p10 < 5
            txTarget(c) = 4;
        else
            txTarget(c) = 2;
        end
    end
    txTarget = min(max(txTarget,0),12);

    action.beam.mode = "adaptive";
    action.radio.txPowerOffset_dB = txTarget(:);
end
