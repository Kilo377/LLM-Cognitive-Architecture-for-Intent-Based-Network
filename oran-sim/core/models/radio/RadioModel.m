classdef RadioModel < handle
%RADIOMODEL v4
%
% Supports:
%   - power.cellTxPowerOffset_dB
%   - energy.basePowerScale
%   - sleep.cellSleepState
%   - radio.bandwidthScale
%   - radio.interferenceMitigation

    properties
        pathlossExp
        shadowingStd_dB
        shadowCorrDist_m

        noiseFigure_dB
        temperature_K

        interfAlpha
        interfMinLoad
        sleepInterfFactor
        loadSmoothFactor

        fastFadeSigmaLow_dB
        fastFadeSigmaHigh_dB
        speedThreshold_mps
        interfJitterSigma_dB

        shadowField
        smoothedLoad
        lastUEPos
    end

    methods

        function obj = RadioModel()

            obj.pathlossExp      = 3.5;
            obj.shadowingStd_dB  = 6;
            obj.shadowCorrDist_m = 50;

            obj.noiseFigure_dB = 7;
            obj.temperature_K  = 290;

            obj.interfAlpha       = 1.2;
            obj.interfMinLoad     = 0.05;
            obj.sleepInterfFactor = [1.0 0.3 0.05];
            obj.loadSmoothFactor  = 0.8;

            obj.fastFadeSigmaLow_dB  = 1.0;
            obj.fastFadeSigmaHigh_dB = 3.0;
            obj.speedThreshold_mps   = 8.0;

            obj.interfJitterSigma_dB = 1.5;

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
            gNB     = ctx.scenario.topology.gNBPos;

            if isempty(obj.shadowField)
                obj.initialize(ctx);
            end

            %% =====================================================
            % 1. Shadow correlation
            %% =====================================================
            deltaPos = vecnorm(ctx.uePos - obj.lastUEPos,2,2);
            obj.lastUEPos = ctx.uePos;

            for u = 1:numUE
                corr = exp(-deltaPos(u)/obj.shadowCorrDist_m);
                newShadow = obj.shadowingStd_dB * randn(1,numCell);
                obj.shadowField(u,:) = ...
                    corr * obj.shadowField(u,:) + ...
                    sqrt(1-corr^2) * newShadow;
            end

            %% =====================================================
            % 2. Tx power baseline
            %% =====================================================
            txPower_dBm = ctx.txPowerCell_dBm * ones(numCell,1);

            % energy scaling -> change Tx baseline
            if ~isempty(ctx.action) && isfield(ctx.action,'energy') && ...
                    isfield(ctx.action.energy,'basePowerScale')

                s = ctx.action.energy.basePowerScale;
                if isnumeric(s) && numel(s)==numCell
                    txPower_dBm = txPower_dBm + 10*log10(max(s(:),1e-6));
                end
            end

            % explicit power offset
            if ~isempty(ctx.action) && isfield(ctx.action,'power') && ...
                    isfield(ctx.action.power,'cellTxPowerOffset_dB')

                off = ctx.action.power.cellTxPowerOffset_dB;
                if isnumeric(off) && numel(off)==numCell
                    txPower_dBm = txPower_dBm + off(:);
                end
            end

            %% =====================================================
            % 3. Load smoothing
            %% =====================================================
            load = ones(numCell,1) * obj.interfMinLoad;

            if isfield(ctx,'tmp') && ...
               isfield(ctx.tmp,'lastPRBUsedPerCell') && ...
               ctx.numPRB > 0

                instLoad = ctx.tmp.lastPRBUsedPerCell(:)/ctx.numPRB;
                instLoad = max(instLoad, obj.interfMinLoad);

                if isempty(obj.smoothedLoad)
                    obj.smoothedLoad = instLoad;
                else
                    obj.smoothedLoad = ...
                        obj.loadSmoothFactor * obj.smoothedLoad + ...
                        (1-obj.loadSmoothFactor) * instLoad;
                end
                load = obj.smoothedLoad;
            end

            %% =====================================================
            % 4. Sleep effect on interference
            %% =====================================================
            sleepFactor = ones(numCell,1);

            if ~isempty(ctx.action) && isfield(ctx.action,'sleep') && ...
                    isfield(ctx.action.sleep,'cellSleepState')

                ss = ctx.action.sleep.cellSleepState;
                if isnumeric(ss) && numel(ss)==numCell
                    for c=1:numCell
                        idx = min(max(round(ss(c))+1,1),3);
                        sleepFactor(c) = obj.sleepInterfFactor(idx);
                    end
                end
            end

            %% =====================================================
            % 5. Interference mitigation flag
            %% =====================================================
            interfMitigationScale = 1.0;

            if ~isempty(ctx.action) && isfield(ctx.action,'radio') && ...
               isfield(ctx.action.radio,'interferenceMitigation') && ...
               ctx.action.radio.interferenceMitigation

                interfMitigationScale = 0.6;
            end

            interfScale = ...
                (load.^obj.interfAlpha) .* ...
                sleepFactor * interfMitigationScale;

            %% =====================================================
            % 6. Noise (bandwidth scaling supported)
            %% =====================================================
            BW = ctx.bandwidthHz;

            if ~isempty(ctx.action) && isfield(ctx.action,'radio') && ...
                    isfield(ctx.action.radio,'bandwidthScale')

                bs = ctx.action.radio.bandwidthScale;
                if isnumeric(bs) && numel(bs)==numCell
                    % assume uniform BW scaling
                    BW = BW * mean(bs);
                end
            end

            kB = 1.38064852e-23;
            noise_W = kB * obj.temperature_K * BW;
            noise_dBm = 10*log10(noise_W) + 30 + obj.noiseFigure_dB;
            noise_W = 10.^((noise_dBm-30)/10);

            %% =====================================================
            % 7. Fast fading
            %% =====================================================
            v_mps = deltaPos / max(ctx.dt,1e-12);

            sigmaFF = obj.fastFadeSigmaLow_dB * ones(numUE,1);
            sigmaFF(v_mps >= obj.speedThreshold_mps) = ...
                obj.fastFadeSigmaHigh_dB;

            fastFadeUE_dB = sigmaFF .* randn(numUE,1);

            %% =====================================================
            % 8. RSRP
            %% =====================================================
            rsrp = zeros(numUE,numCell);

            for c = 1:numCell

                d = vecnorm(ctx.uePos - gNB(c,:),2,2);
                d = max(d,1);

                pl_dB = 10*obj.pathlossExp*log10(d);

                beamGain = 0;
                if isfield(ctx.tmp,'beamGain_dB')
                    beamGain = ctx.tmp.beamGain_dB(:,c);
                end

                rsrp(:,c) = ...
                    txPower_dBm(c) - pl_dB + ...
                    obj.shadowField(:,c) + ...
                    fastFadeUE_dB + beamGain;
            end

            ctx.rsrp_dBm = rsrp;

            %% =====================================================
            % 9. SINR
            %% =====================================================
            sinr_dB = zeros(numUE,1);
            interfJitterCell_dB = ...
                obj.interfJitterSigma_dB * randn(numCell,1);

            for u = 1:numUE

                s = ctx.servingCell(u);

                sig_W = 10.^((rsrp(u,s)-30)/10);

                interf_W = 0;

                for c = 1:numCell
                    if c==s, continue; end

                    p_dBm = rsrp(u,c) + interfJitterCell_dB(c);
                    p_W   = 10.^((p_dBm-30)/10);

                    interf_W = interf_W + p_W * interfScale(c);
                end

                sinr_W = sig_W/(interf_W + noise_W + 1e-15);
                sinr_dB(u) = 10*log10(sinr_W);
            end

            ctx.sinr_dB = sinr_dB;
            
            %% =======================print==============================
            %if ctx.slot <= 5
            %    fprintf("Slot %d mean SINR = %.2f dB\n", ...
            %        ctx.slot, mean(ctx.sinr_dB));
            %end

       

            %% =====================================================
            % 10. Post-HO penalty
            %% =====================================================
            if isfield(ctx,'uePostHoUntilSlot') && ...
               isfield(ctx,'uePostHoSinrPenalty_dB')

                for u=1:numUE
                    if ctx.slot < ctx.uePostHoUntilSlot(u)
                        ctx.sinr_dB(u) = ...
                            ctx.sinr_dB(u) - ...
                            ctx.uePostHoSinrPenalty_dB(u);
                    else
                        ctx.uePostHoSinrPenalty_dB(u) = 0;
                    end
                end
            end

            %% =====================================================
            % 11. Observability
            %% =====================================================
            ctx.tmp.meanSinr_dB = mean(ctx.sinr_dB);
        end
    end
end
