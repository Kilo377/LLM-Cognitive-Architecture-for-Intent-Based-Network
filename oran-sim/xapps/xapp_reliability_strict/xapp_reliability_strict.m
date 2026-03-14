%{
Author: Chongyu Bao (zt25108@bristol.ac.uk)

File: xapp_reliability_strict.m

Description:
Reliability-oriented xApp.
Minimizes BLER and protects edge UEs.
Increases Tx power and bandwidth when edge SINR is low.
May increase energy consumption.
%}

function action = xapp_reliability_strict(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;
    numUE   = obs.topology.numUE;

    action = struct();

    %% Read observations
    sinr = zeros(numUE,1);
    sc   = ones(numUE,1);

    if isfield(obs,'ue')
        if isfield(obs.ue,'sinr_dB')
            sinr = obs.ue.sinr_dB(:);
        end
        if isfield(obs.ue,'servingCell')
            sc = obs.ue.servingCell(:);
        end
    end

    prbUtil = zeros(numCell,1);
    if isfield(obs,'cell') && isfield(obs.cell,'prbUtil')
        prbUtil = obs.cell.prbUtil(:);
    end

    %% Initialize outputs
    txOff = zeros(numCell,1);
    bw    = ones(numCell,1);

    for c = 1:numCell

        ueIdx = find(sc == c);
        if isempty(ueIdx)
            continue;
        end

        p10 = prctile(sinr(ueIdx),10);
        p50 = prctile(sinr(ueIdx),50);

        % ---- Edge protection ----
        if p10 < -5
            txOff(c) = 12;
            bw(c)    = 1.5;
        elseif p10 < 0
            txOff(c) = 8;
            bw(c)    = 1.3;
        elseif p50 < 5
            txOff(c) = 5;
            bw(c)    = 1.2;
        else
            txOff(c) = 2;
            bw(c)    = 1.1;
        end

        % ---- Congestion compensation ----
        if prbUtil(c) > 0.8
            bw(c) = bw(c) + 0.3;
        end

    end

    txOff = min(max(txOff,-5),20);
    bw    = min(max(bw,0.8),3.0);

    action.radio.txPowerOffset_dB = txOff;
    action.radio.bandwidthScale   = bw;

    action.energy.basePowerScale = ones(numCell,1);
    action.sleep.cellSleepState  = zeros(numCell,1);

end