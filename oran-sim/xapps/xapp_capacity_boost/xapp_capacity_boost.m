function action = xapp_capacity_boost(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;
    numUE   = obs.topology.numUE;

    action = struct();

    persistent lastTxOff lastBwScale initDone
    if isempty(initDone)
        lastTxOff  = zeros(numCell,1);
        lastBwScale = ones(numCell,1);
        initDone = true;
    end

    servingCell = ones(numUE,1);
    sinr_dB = zeros(numUE,1);
    bufferBits = zeros(numUE,1);

    if isfield(obs,'ue')
        if isfield(obs.ue,'servingCell')
            servingCell = obs.ue.servingCell(:);
        end
        if isfield(obs.ue,'sinr_dB')
            sinr_dB = double(obs.ue.sinr_dB(:));
        end
        if isfield(obs.ue,'buffer_bits')
            bufferBits = double(obs.ue.buffer_bits(:));
        end
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

    bufCell = zeros(numCell,1);
    for c = 1:numCell
        ueIdx = find(servingCell == c);
        if ~isempty(ueIdx)
            bufCell(c) = sum(bufferBits(ueIdx));
        end
    end

    bufRef = median(bufCell) + 1;
    bufNorm = min(max(bufCell ./ bufRef, 0), 5);

    loadScore = 0.6 * prbUtil + 0.4 * min(bufNorm/2, 1.0);

    bwTarget = 0.8 + 1.6 * loadScore;
    bwTarget = min(max(bwTarget,0.8),2.4);

    txTarget = -1.0 + 10.0 * loadScore;

    for c = 1:numCell
        ueIdx = find(servingCell == c);
        if isempty(ueIdx)
            continue;
        end
        p10 = prctile(sinr_dB(ueIdx),10);
        if p10 < 0
            txTarget(c) = txTarget(c) + 2.0;
        end
        if p10 < -5
            txTarget(c) = txTarget(c) + 3.0;
        end
    end
    txTarget = min(max(txTarget,-2.0),12.0);

    alpha = 0.80;
    bwOut = alpha * lastBwScale + (1-alpha) * bwTarget;
    txOut = alpha * lastTxOff  + (1-alpha) * txTarget;

    lastBwScale = bwOut;
    lastTxOff   = txOut;

    action.radio.bandwidthScale   = bwOut(:);
    action.radio.txPowerOffset_dB = txOut(:);

    action.scheduling.selectedUE = zeros(numCell,1);
    action.scheduling.weightUE   = ones(numUE,1);

    for c = 1:numCell
        ueIdx = find(servingCell == c);
        if isempty(ueIdx)
            continue;
        end

        b = bufferBits(ueIdx);
        s = sinr_dB(ueIdx);

        bNorm = b / (median(b) + 1);
        sLin  = 10.^(s/10);

        score = (0.7 * min(bNorm,5) + 0.3) .* (sLin.^0.25);
        [~,k] = max(score);
        action.scheduling.selectedUE(c) = ueIdx(k);
    end
end
