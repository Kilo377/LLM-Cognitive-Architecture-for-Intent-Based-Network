function action = xapp_energy_saver(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;
    numUE   = obs.topology.numUE;

    action = struct();

    persistent lastTxOff lastBwScale lastPwrScale lastSleep initDone
    if isempty(initDone)
        lastTxOff  = zeros(numCell,1);
        lastBwScale = ones(numCell,1);
        lastPwrScale = ones(numCell,1);
        lastSleep = zeros(numCell,1);
        initDone = true;
    end

    prbUtil = zeros(numCell,1);
    if isfield(obs,'cell') && isfield(obs.cell,'prbUtil')
        prbUtil = double(obs.cell.prbUtil(:));
    elseif isfield(obs,'kpi') && isfield(obs.kpi,'prbUtilPerCell')
        prbUtil = double(obs.kpi.prbUtilPerCell(:));
    end
    if numel(prbUtil) ~= numCell
        prbUtil = zeros(numCell,1);
    end
    prbUtil = min(max(prbUtil,0),1);

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

    txTarget  = zeros(numCell,1);
    bwTarget  = zeros(numCell,1);
    pwrTarget = zeros(numCell,1);
    sleepState = zeros(numCell,1);

    for c = 1:numCell
        load = prbUtil(c);

        if load < 0.10
            sleepState(c) = 2;
            txTarget(c)   = -10;
            bwTarget(c)   = 0.40;
            pwrTarget(c)  = 0.35;
        elseif load < 0.30
            txTarget(c)   = -8;
            bwTarget(c)   = 0.50;
            pwrTarget(c)  = 0.45;
        elseif load < 0.60
            txTarget(c)   = -6;
            bwTarget(c)   = 0.70;
            pwrTarget(c)  = 0.60;
        else
            txTarget(c)   = -4;
            bwTarget(c)   = 0.90;
            pwrTarget(c)  = 0.75;
        end

        ueIdx = find(servingCell == c);
        if isempty(ueIdx)
            continue;
        end
        p10 = prctile(sinr_dB(ueIdx),10);
        if p10 < -5
            txTarget(c) = max(txTarget(c), -2);
            bwTarget(c) = max(bwTarget(c), 0.90);
            sleepState(c) = min(sleepState(c), 1);
        elseif p10 < 0
            txTarget(c) = max(txTarget(c), -4);
            bwTarget(c) = max(bwTarget(c), 0.80);
        end
    end

    txTarget  = min(max(txTarget,-12),0);
    bwTarget  = min(max(bwTarget,0.35),1.0);
    pwrTarget = min(max(pwrTarget,0.30),1.0);

    alpha = 0.85;
    txOut = alpha * lastTxOff + (1-alpha) * txTarget;
    bwOut = alpha * lastBwScale + (1-alpha) * bwTarget;
    pwrOut = alpha * lastPwrScale + (1-alpha) * pwrTarget;
    sleepOut = round(alpha * lastSleep + (1-alpha) * sleepState);

    lastTxOff = txOut;
    lastBwScale = bwOut;
    lastPwrScale = pwrOut;
    lastSleep = sleepOut;

    action.radio.txPowerOffset_dB = txOut(:);
    action.radio.bandwidthScale   = bwOut(:);
    action.energy.basePowerScale  = pwrOut(:);
    action.sleep.cellSleepState   = sleepOut(:);
end
