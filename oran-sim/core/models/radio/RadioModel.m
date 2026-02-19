classdef RadioModel < handle
%RADIOMODEL v7.0 (ctrl-only + interferenceCouplingFactor + unified debug)
%
% Fixes:
%   1) Read ctrl only. Do not read ctx.action.
%   2) Add interferenceCouplingFactor:
%        power ↑ -> interference ↑
%        bandwidth ↑ -> interference ↑
%        load ↑ -> interference ↑
%   3) Unified debug interface:
%        ctx.debug.trace.radio
%        optional printing via cfg.debug
%
% Reads:
%   ctx.txPowerCell_dBm
%   ctx.bandwidthHzPerCell (or ctx.bandwidthHz)
%   ctx.numPRBPerCell (or ctx.numPRB)
%   ctx.lastPRBUsedPerCell_slot
%   ctx.ctrl.cellSleepState
%   ctx.uePos, ctx.dt, ctx.servingCell
%   ctx.tmp.beamGain_dB (optional)
%   ctx.scenario.topology.gNBPos (or gNBPos_m)
%
% Writes:
%   ctx.rsrp_dBm
%   ctx.sinr_dB
%   ctx.tmp.meanSinr_dB
%   ctx.tmp.channel.interference_dBm / noise_dBm (per UE)
%   ctx.debug.trace.radio

    properties
        % Large-scale channel
        pathlossExp
        shadowingStd_dB
        shadowCorrDist_m

        % Noise
        noiseFigure_dB
        temperature_K

        % Interference/load base model
        interfAlpha
        interfMinLoad
        sleepInterfFactor
        loadSmoothFactor

        % NEW: Coupling factors
        % kTx:  per-dB sensitivity of interference (relative to median cell Tx)
        % kBw:  exponent on BW ratio
        % kLoadExtra: extra exponent on load ratio (in addition to interfAlpha)
        interferenceCouplingFactor

        % Small-scale fading
        fastFadeSigmaLow_dB
        fastFadeSigmaHigh_dB
        speedThreshold_mps

        % Interference jitter
        interfJitterSigma_dB

        % Internal state
        shadowField
        smoothedLoad
        lastUEPos
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

            % Coupling
            obj.interferenceCouplingFactor = struct();
            obj.interferenceCouplingFactor.kTx_dB  = 0.20; % 0.20 means +10 dB -> ~+2 dB interf effect
            obj.interferenceCouplingFactor.kBw     = 0.60; % BW ratio exponent
            obj.interferenceCouplingFactor.kLoadExtra = 0.30; % extra exponent on load ratio

            % Fast fading
            obj.fastFadeSigmaLow_dB  = 1.0;
            obj.fastFadeSigmaHigh_dB = 3.0;
            obj.speedThreshold_mps   = 8.0;

            % Per-cell random jitter on interferers
            obj.interfJitterSigma_dB = 1.5;

            % Internal
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
            % 2) Tx power (runtime single source)
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
            % 3) PRB total/used and load smoothing (persistent source)
            % =====================================================
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
            % 4) Sleep interference scaling (ctrl only)
            % =====================================================
            sleepFactor = ones(numCell,1);
            ss = ctx.ctrl.cellSleepState(:);
            if numel(ss) == numCell
                for c = 1:numCell
                    idx = min(max(round(ss(c)) + 1, 1), 3);
                    sleepFactor(c) = obj.sleepInterfFactor(idx);
                end
            end

            % =====================================================
            % 5) Bandwidth + noise (per cell, include NF)
            % =====================================================
            BWcell = ctx.bandwidthHz * ones(numCell,1);
            if isfield(ctx,'bandwidthHzPerCell') && numel(ctx.bandwidthHzPerCell) == numCell
                BWcell = ctx.bandwidthHzPerCell(:);
            end
            BWcell = max(BWcell, 1e3);

            kB = 1.38064852e-23;
            noiseWcell = kB * obj.temperature_K .* BWcell;
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
            % 8) Interference scale with coupling factors
            % =====================================================
            % Load part
            kLoadExtra = obj.interferenceCouplingFactor.kLoadExtra;
            loadPart = (max(load, obj.interfMinLoad) .^ (obj.interfAlpha + kLoadExtra));

            % Tx power part (relative to median)
            kTx = obj.interferenceCouplingFactor.kTx_dB;
            txRef = median(txPower_dBm);
            txDelta_dB = txPower_dBm - txRef;
            txPart = 10.^((kTx * txDelta_dB) / 10);
            txPart = min(max(txPart, 0.1), 10);

            % BW part (relative to median)
            kBw = obj.interferenceCouplingFactor.kBw;
            bwRef = median(BWcell);
            if bwRef <= 0, bwRef = 1; end
            bwRatio = BWcell / bwRef;
            bwPart = bwRatio .^ kBw;
            bwPart = min(max(bwPart, 0.1), 10);

            % Final per-cell interference multiplier
            interfScale = sleepFactor .* loadPart .* txPart .* bwPart;

            % =====================================================
            % 9) SINR
            % =====================================================
            sinr_dB = zeros(numUE,1);

            interfJitterCell_dB = obj.interfJitterSigma_dB * randn(numCell,1);

            if ~isfield(ctx,'tmp') || ~isstruct(ctx.tmp)
                ctx.tmp = struct();
            end
            if ~isfield(ctx.tmp,'channel') || isempty(ctx.tmp.channel)
                ctx.tmp.channel = struct();
            end
            ctx.tmp.channel.interference_dBm = nan(numUE,1);
            ctx.tmp.channel.noise_dBm        = nan(numUE,1);

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

                if interf_W > 0
                    ctx.tmp.channel.interference_dBm(u) = 10*log10(interf_W) + 30;
                else
                    ctx.tmp.channel.interference_dBm(u) = -inf;
                end
                ctx.tmp.channel.noise_dBm(u) = 10*log10(max(noise_W,1e-20)) + 30;
            end

            ctx.sinr_dB = sinr_dB;

            % =====================================================
            % 10) Post-HO penalty
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
            % 11) Observability
            % =====================================================
            ctx.tmp.meanSinr_dB = mean(ctx.sinr_dB);

            % =====================================================
            % 12) Unified debug trace + optional print
            % =====================================================
            ctx = obj.writeDebugTrace(ctx, txPower_dBm, BWcell, prbUsed, prbTotal, load, sleepFactor, interfScale);

            if obj.shouldPrint(ctx)
                obj.printDebug(ctx);
            end
        end
    end

    methods (Access = private)

        function ctx = writeDebugTrace(~, ctx, txPower_dBm, BWcell, prbUsed, prbTotal, load, sleepFactor, interfScale)
    
            % ==== MUST use ctx.tmp.debug ====
    
            if isempty(ctx.tmp)
                ctx.tmp = struct();
            end
            if ~isfield(ctx.tmp,'debug') || isempty(ctx.tmp.debug)
                ctx.tmp.debug = struct();
            end
            if ~isfield(ctx.tmp.debug,'trace') || isempty(ctx.tmp.debug.trace)
                ctx.tmp.debug.trace = struct();
            end
    
            tr = struct();
            tr.slot = ctx.slot;
    
            tr.cell = struct();
            tr.cell.txPower_dBm  = txPower_dBm(:);
            tr.cell.bandwidthHz  = BWcell(:);
            tr.cell.prbUsed      = prbUsed(:);
            tr.cell.prbTotal     = prbTotal(:);
            tr.cell.load         = load(:);
            tr.cell.sleepFactor  = sleepFactor(:);
            tr.cell.interfScale  = interfScale(:);
    
            tr.ue = struct();
            tr.ue.meanSinr_dB = mean(ctx.sinr_dB);
            tr.ue.minSinr_dB  = min(ctx.sinr_dB);
            tr.ue.maxSinr_dB  = max(ctx.sinr_dB);
    
            if isfield(ctx.tmp,'channel')
                interf = ctx.tmp.channel.interference_dBm;
                noise  = ctx.tmp.channel.noise_dBm;
    
                if ~isempty(interf)
                    tr.ue.meanInterf_dBm = mean(interf(isfinite(interf)));
                else
                    tr.ue.meanInterf_dBm = NaN;
                end
    
                if ~isempty(noise)
                    tr.ue.meanNoise_dBm = mean(noise(isfinite(noise)));
                else
                    tr.ue.meanNoise_dBm = NaN;
                end
            end
    
            ctx.tmp.debug.trace.radio = tr;
        end
    
    
        function tf = shouldPrint(~, ctx)
    
            tf = false;
    
            if ~isfield(ctx.cfg,'debug'), return; end
            if ~isfield(ctx.cfg.debug,'enable'), return; end
            if ~ctx.cfg.debug.enable, return; end
    
            every = 1;
            if isfield(ctx.cfg.debug,'every') && ctx.cfg.debug.every >= 1
                every = round(ctx.cfg.debug.every);
            end
    
            if mod(ctx.slot, every) ~= 0
                return;
            end
    
            if isfield(ctx.cfg.debug,'modules')
                try
                    ms = string(ctx.cfg.debug.modules);
                    if ~any(ms=="radio") && ~any(ms=="all")
                        return;
                    end
                catch
                end
            end
    
            tf = true;
        end
    
    
        function printDebug(~, ctx)
    
            if ~isfield(ctx.tmp,'debug'), return; end
            if ~isfield(ctx.tmp.debug,'trace'), return; end
            if ~isfield(ctx.tmp.debug.trace,'radio'), return; end
    
            tr = ctx.tmp.debug.trace.radio;
    
            fprintf('[DEBUG][slot=%d][radio] meanSINR=%.2f dB  min=%.2f  max=%.2f\n', ...
                tr.slot, tr.ue.meanSinr_dB, tr.ue.minSinr_dB, tr.ue.maxSinr_dB);
    
            numCell = numel(tr.cell.txPower_dBm);
            for c = 1:numCell
                fprintf('  cell=%d tx=%.1f dBm bw=%.2f MHz load=%.2f interfScale=%.3f sleepFactor=%.2f\n', ...
                    c, ...
                    tr.cell.txPower_dBm(c), ...
                    tr.cell.bandwidthHz(c)/1e6, ...
                    tr.cell.load(c), ...
                    tr.cell.interfScale(c), ...
                    tr.cell.sleepFactor(c));
            end
    
            if isfield(tr.ue,'meanInterf_dBm') && isfinite(tr.ue.meanInterf_dBm)
                fprintf('  UE meanInterf=%.2f dBm  meanNoise=%.2f dBm\n', ...
                    tr.ue.meanInterf_dBm, tr.ue.meanNoise_dBm);
            end
        end
    
    end

end
