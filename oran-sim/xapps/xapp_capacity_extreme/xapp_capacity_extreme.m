%{
Author: Chongyu Bao (zt25108@bristol.ac.uk)

File: xapp_capacity_extreme.m

Description:
Online capacity boosting xApp.
This xApp increases throughput under congestion.
It uses buffer and PRB utilization as load signals.
It applies per-cell adaptive bandwidthScale and txPowerOffset_dB.
It keeps a small smoothing memory to avoid oscillation.
%}

function action = xapp_capacity_extreme(input)
    obs = input.measurements;

    numCell = obs.topology.numCell;
    numUE   = obs.topology.numUE;

    action = struct();

    % =========================
    % Persistent online state
    % =========================
    persistent lastTxOff lastBwScale initDone debugFlag
    if isempty(initDone)
        lastTxOff  = zeros(numCell,1);
        lastBwScale = ones(numCell,1);
        initDone = true;
        debugFlag = false;
    end

    % =========================
    % Read observables
    % =========================
    if isfield(obs,'ue') && isfield(obs.ue,'servingCell')
        servingCell = obs.ue.servingCell(:);
    else
        servingCell = ones(numUE,1);
    end

    if isfield(obs,'ue') && isfield(obs.ue,'sinr_dB')
        sinr_dB = obs.ue.sinr_dB(:);
    else
        sinr_dB = zeros(numUE,1);
    end

    if isfield(obs,'ue') && isfield(obs.ue,'buffer_bits')
        bufferBits = double(obs.ue.buffer_bits(:));
    else
        bufferBits = zeros(numUE,1);
    end

    if isfield(obs,'cell') && isfield(obs.cell,'prbUtil')
        prbUtil = double(obs.cell.prbUtil(:));
    elseif isfield(obs,'kpi') && isfield(obs.kpi,'prbUtilPerCell')
        prbUtil = double(obs.kpi.prbUtilPerCell(:));
    else
        prbUtil = zeros(numCell,1);
    end
    if numel(prbUtil) ~= numCell
        prbUtil = zeros(numCell,1);
    end
    prbUtil = min(max(prbUtil,0),1);

    % per-cell buffered bits
    bufCell = zeros(numCell,1);
    for c = 1:numCell
        ueIdx = find(servingCell == c);
        if ~isempty(ueIdx)
            bufCell(c) = sum(bufferBits(ueIdx));
        end
    end

    bufRef = median(bufCell) + 1;
    bufNorm = bufCell ./ bufRef;
    bufNorm = min(max(bufNorm,0),5);

    % =========================
    % Online control targets
    % =========================
    % If PRB util high or buffer high -> push resources.
    loadScore = 0.65 * prbUtil + 0.35 * min(bufNorm/2,1.0);

    % bandwidthScale target in [0.5, 3.0]
    bwTarget = 0.6 + 2.4 * loadScore;
    bwTarget = min(max(bwTarget,0.5),3.0);

    % txPowerOffset target in [-5, +18] by load and edge SINR
    txTarget = -1.0 + 19.0 * loadScore;

    % add edge protection: if cell has many low SINR UEs, increase power more
    for c = 1:numCell
        ueIdx = find(servingCell == c);
        if isempty(ueIdx)
            continue;
        end
        s = sinr_dB(ueIdx);
        p10 = prctile(s,10);
        if p10 < 0
            txTarget(c) = txTarget(c) + 4.0;
        end
        if p10 < -5
            txTarget(c) = txTarget(c) + 4.0;
        end
    end
    txTarget = min(max(txTarget,-5.0),18.0);

    % =========================
    % Smoothing to avoid oscillation
    % =========================
    alpha = 0.85; % larger means smoother
    bwOut = alpha * lastBwScale + (1-alpha) * bwTarget;
    txOut = alpha * lastTxOff  + (1-alpha) * txTarget;

    lastBwScale = bwOut;
    lastTxOff   = txOut;

    % =========================
    % Action pack
    % =========================
    action.radio.bandwidthScale   = bwOut(:);
    action.radio.txPowerOffset_dB = txOut(:);

    % =========================
    % Scheduling: pick UE with best "drain buffer" priority
    % =========================
    action.scheduling.selectedUE = zeros(numCell,1);
    action.scheduling.weightUE   = ones(numUE,1);

    for c = 1:numCell
        ueIdx = find(servingCell == c);
        if isempty(ueIdx)
            continue;
        end

        % score: prefer high buffer and decent SINR
        b = bufferBits(ueIdx);
        s = sinr_dB(ueIdx);

        bNorm = b / (median(b)+1);
        sLin  = 10.^(s/10);

        score = (0.7 * min(bNorm,5) + 0.3) .* (sLin.^0.25);

        [~,k] = max(score);
        action.scheduling.selectedUE(c) = ueIdx(k);
    end

    % =========================
    % Optional print
    % =========================
    if debugFlag
        fprintf('[xapp_capacity_extreme] bw=%s txOff=%s prbUtil=%s bufCell=%s\n', ...
            mat2str(bwOut(:).',3), mat2str(txOut(:).',3), ...
            mat2str(prbUtil(:).',3), mat2str(bufCell(:).',3));
    end
end