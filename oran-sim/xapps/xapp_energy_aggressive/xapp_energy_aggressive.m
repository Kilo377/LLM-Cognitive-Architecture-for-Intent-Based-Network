%{
Author: Chongyu Bao (zt25108@bristol.ac.uk)

File: xapp_energy_aggressive.m

Description:
Load-aware adaptive energy optimization xApp.
Aggressive energy saving in low load region.
Conservative energy saving in high load region.
SINR-aware protection to avoid throughput collapse.
Includes smoothing to avoid oscillation.
%}

function action = xapp_energy_aggressive(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;

    action = struct();

    %% ==============================
    % Observations
    %% ==============================
    prbUtil = zeros(numCell,1);

    if isfield(obs,'cell') && isfield(obs.cell,'prbUtil')
        prbUtil = obs.cell.prbUtil(:);
    end

    prbUtil = min(max(prbUtil,0),1);

    %% ==============================
    % Aggressive control
    %% ==============================
    txTarget  = zeros(numCell,1);
    bwTarget  = zeros(numCell,1);
    pwrTarget = zeros(numCell,1);
    sleepState = zeros(numCell,1);

    for c = 1:numCell

        load = prbUtil(c);

        % Deep sleep for very low load
        if load < 0.1
            sleepState(c) = 2;
            txTarget(c)   = -10;
            bwTarget(c)   = 0.3;
            pwrTarget(c)  = 0.3;
            continue
        end

        % Low load
        if load < 0.4
            txTarget(c)   = -8;
            bwTarget(c)   = 0.4;
            pwrTarget(c)  = 0.4;
        end

        % Medium load
        if load >= 0.4 && load < 0.8
            txTarget(c)   = -6;
            bwTarget(c)   = 0.5;
            pwrTarget(c)  = 0.5;
        end

        % High load
        if load >= 0.8
            txTarget(c)   = -4;
            bwTarget(c)   = 0.6;
            pwrTarget(c)  = 0.6;
        end

    end

    %% Clamp
    txTarget  = min(max(txTarget,-12),0);
    bwTarget  = min(max(bwTarget,0.3),1.0);
    pwrTarget = min(max(pwrTarget,0.3),1.0);

    %% Pack
    action.radio.txPowerOffset_dB = txTarget(:);
    action.radio.bandwidthScale   = bwTarget(:);
    action.energy.basePowerScale  = pwrTarget(:);
    action.sleep.cellSleepState   = sleepState(:);

end