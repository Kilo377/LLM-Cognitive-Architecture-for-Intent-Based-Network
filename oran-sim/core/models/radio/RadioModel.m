classdef RadioModel < handle
%RADIOMODEL v6 (ctrl-first + stable + per-cell knobs)
%
% What this version fixes
%   1) Single source of truth:
%        - Tx power:      ctx.txPowerCell_dBm (vector preferred)
%        - Bandwidth:     ctx.bandwidthHzPerCell (vector preferred)
%        - Sleep state:   ctx.ctrl.cellSleepState (persistent, survives tmp reset)
%   2) Noise uses per-cell bandwidth and includes Noise Figure in dB.
%   3) Interference load smoothing does NOT rely on ctx.tmp from the same slot.
%      It consumes ctx.lastPRBUsedPerCell_slot and ctx.numPRBPerCell (both persistent).
%   4) gNB position field compatibility: gNBPos or gNBPos_m.
%   5) Safe guards for scalar/vector mismatch everywhere.
%
% Control philosophy
%   - Energy scaling MUST NOT affect radio.
%   - Sleep affects interference via sleepInterfFactor.
%   - Coverage reduction from sleep is already handled in ActionApplier (Tx power penalty).

    properties
        % Large-scale channel
        pathlossExp
        shadowingStd_dB
        shadowCorrDist_m

        % Noise
        noiseFigure_dB
        temperature_K

        % Interference/load model
        interfAlpha
        interfMinLoad
        sleepInterfFactor
        loadSmoothFactor

        % Small-scale fading
        fastFadeSigmaLow_dB
        fastFadeSigmaHigh_dB
        speedThreshold_mps

        % Interference jitter
        interfJitterSigma_dB

        % Internal state
        shadowField          % [numUE x numCell]
        smoothedLoad         % [numCell x 1]
        lastUEPos            % [numUE x dim]
    end

    methods
        function obj = RadioModel()

            % Large-scale
            obj.pathlossExp      = 3.5;
            obj.shadowingStd_dB  = 6;
            obj.shadowCorrDist_m = 50;

            % Noise
            obj.noiseFigure_dB = 7;
            obj.temperature_K  = 290;

            % Interference/load
            obj.interfAlpha       = 1.2;
            obj.interfMinLoad     = 0.05;
            obj.sleepInterfFactor = [1.0 0.3 0.05];  % state 0/1/2
            obj.loadSmoothFactor  = 0.8;

            % Fast fading
            obj.fastFadeSigmaLow_dB  = 1.0;
            obj.fastFadeSigmaHigh_dB = 3.0;
            obj.speedThreshold_mps   = 8.0;

            % Per-cell random jitter on interferers
            obj.interfJitterSigma_dB = 1.5;

            % Internal buffers
            obj.shadowField  = [];
            obj.smoothedLoad = [];
            obj.lastUEPos    = [];
        end

        function initialize(obj, ctx)
            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            obj.shadowField  = obj.shadowingStd_dB * randn(numUE, numCell);
            obj.smoothedLoad = ones(numCell,1) * 0.5;
            obj.lastUEPos    = ctx.uePos;
        end

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            % -----------------------------
            % gNB position compatibility
            % -----------------------------
            if isfield(ctx.scenario,'topology') && isfield(ctx.scenario.topology,'gNBPos')
                gNB = ctx.scenario.topology.gNBPos;
            else
                gNB = ctx.scenario.topology.gNBPos_m;
            end

            if isempty(obj.shadowField)
                obj.initialize(ctx);
            end

            % =====================================================
            % 1) Shadow correlation update
            % =====================================================
            deltaPos = vecnorm(ctx.uePos - obj.lastUEPos, 2, 2);
            obj.lastUEPos = ctx.uePos;

            for u = 1:numUE
                corr = exp(-deltaPos(u) / obj.shadowCorrDist_m);
                newShadow = obj.shadowingStd_dB * randn(1, numCell);
                obj.shadowField(u,:) = ...
                    corr * obj.shadowField(u,:) + ...
                    sqrt(max(1 - corr^2, 0)) * newShadow;
            end

            % =====================================================
            % 2) Tx power (single source of truth)
            % =====================================================
            tx = ctx.txPowerCell_dBm;
            if isscalar(tx)
                txPower_dBm = tx * ones(numCell,1);
            else
                txPower_dBm = tx(:);
            end
            if numel(txPower_dBm) ~= numCell
                txPower_dBm = txPower_dBm(1) * ones(numCell,1);
            end
            txPower_dBm = min(max(txPower_dBm, -50), 80);

            % =====================================================
            % 3) Load smoothing (persistent source, not tmp)
            % =====================================================
            % We prefer lastPRBUsedPerCell_slot because ctx.tmp is cleared each slot.
            prbTotal = ctx.numPRB * ones(numCell,1);
            if isfield(ctx,'numPRBPerCell') && numel(ctx.numPRBPerCell) == numCell
                prbTotal = ctx.numPRBPerCell(:);
            end
            prbTotal(prbTotal <= 0) = 1;

            prbUsed = zeros(numCell,1);
            if isfield(ctx,'lastPRBUsedPerCell_slot') && numel(ctx.lastPRBUsedPerCell_slot) == numCell
                prbUsed = ctx.lastPRBUsedPerCell_slot(:);
            end

            instLoad = prbUsed ./ prbTotal;
            instLoad = max(instLoad, obj.interfMinLoad);
            instLoad = min(instLoad, 1);

            if isempty(obj.smoothedLoad) || numel(obj.smoothedLoad) ~= numCell
                obj.smoothedLoad = instLoad;
            else
                obj.smoothedLoad = ...
                    obj.loadSmoothFactor * obj.smoothedLoad + ...
                    (1 - obj.loadSmoothFactor) * instLoad;
            end

            load = obj.smoothedLoad;

            % =====================================================
            % 4) Sleep interference scaling (use ctx.ctrl)
            % =====================================================
            sleepFactor = ones(numCell,1);

            if isfield(ctx,'ctrl') && isfield(ctx.ctrl,'cellSleepState')
                ss = ctx.ctrl.cellSleepState(:);
                if numel(ss) == numCell
                    for c = 1:numCell
                        idx = min(max(round(ss(c)) + 1, 1), 3);
                        sleepFactor(c) = obj.sleepInterfFactor(idx);
                    end
                end
            end

            interfScale = (load .^ obj.interfAlpha) .* sleepFactor;

            % =====================================================
            % 5) Per-cell bandwidth + noise (include NF)
            % =====================================================
            BWcell = ctx.bandwidthHz * ones(numCell,1);
            if isfield(ctx,'bandwidthHzPerCell') && numel(ctx.bandwidthHzPerCell) == numCell
                BWcell = ctx.bandwidthHzPerCell(:);
            end
            BWcell = max(BWcell, 1e3);

            % Thermal noise: kT*B, then apply noise figure
            kB = 1.38064852e-23;
            noiseWcell = kB * obj.temperature_K .* BWcell;      % W
            NF_lin = 10^(obj.noiseFigure_dB/10);
            noiseWcell = noiseWcell .* NF_lin;
            noiseWcell = max(noiseWcell, 1e-20);

            % =====================================================
            % 6) Fast fading (UE-based)
            % =====================================================
            v_mps = deltaPos / max(ctx.dt, 1e-12);

            sigmaFF = obj.fastFadeSigmaLow_dB * ones(numUE,1);
            sigmaFF(v_mps >= obj.speedThreshold_mps) = obj.fastFadeSigmaHigh_dB;

            fastFadeUE_dB = sigmaFF .* randn(numUE,1);

            % =====================================================
            % 7) RSRP per UE per cell
            % =====================================================
            rsrp = zeros(numUE, numCell);

            for c = 1:numCell
                d = vecnorm(ctx.uePos - gNB(c,:), 2, 2);
                d = max(d, 1);

                pl_dB = 10 * obj.pathlossExp * log10(d);

                beamGain_dB = 0;
                if isfield(ctx,'tmp') && isfield(ctx.tmp,'beamGain_dB')
                    bg = ctx.tmp.beamGain_dB(:,c);
                    if numel(bg) == numUE
                        beamGain_dB = bg;
                    end
                end

                rsrp(:,c) = ...
                    txPower_dBm(c) - pl_dB + ...
                    obj.shadowField(:,c) + ...
                    fastFadeUE_dB + ...
                    beamGain_dB;
            end

            ctx.rsrp_dBm = rsrp;

            % =====================================================
            % 8) SINR (interference uses interfScale)
            % =====================================================
            sinr_dB = zeros(numUE,1);
            interfJitterCell_dB = obj.interfJitterSigma_dB * randn(numCell,1);

            for u = 1:numUE
                s = ctx.servingCell(u);
                if s < 1 || s > numCell
                    s = 1;
                end

                sig_W = 10.^((rsrp(u,s) - 30)/10);

                interf_W = 0;
                for c = 1:numCell
                    if c == s
                        continue;
                    end
                    p_dBm = rsrp(u,c) + interfJitterCell_dB(c);
                    p_W   = 10.^((p_dBm - 30)/10);
                    interf_W = interf_W + p_W * interfScale(c);
                end

                noise_W = noiseWcell(s);

                sinr_W = sig_W / (interf_W + noise_W + 1e-15);
                sinr_dB(u) = 10*log10(max(sinr_W, 1e-12));
            end

            ctx.sinr_dB = sinr_dB;

            % =====================================================
            % 9) Post-HO penalty
            % =====================================================
            if isfield(ctx,'uePostHoUntilSlot') && isfield(ctx,'uePostHoSinrPenalty_dB')
                for u = 1:numUE
                    if ctx.slot < ctx.uePostHoUntilSlot(u)
                        ctx.sinr_dB(u) = ctx.sinr_dB(u) - ctx.uePostHoSinrPenalty_dB(u);
                    else
                        ctx.uePostHoSinrPenalty_dB(u) = 0;
                    end
                end
            end

            % =====================================================
            % 10) Observability
            % =====================================================
            if ~isfield(ctx,'tmp') || ~isstruct(ctx.tmp)
                ctx.tmp = struct();
            end
            ctx.tmp.meanSinr_dB = mean(ctx.sinr_dB);
        end
    end
end
