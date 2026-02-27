classdef RadioModel < handle
% RADIOMODEL v9.0 (ORAN Conflict-Oriented Version)
%
% 目标：
%   - Beam真正参与RSRP
%   - Fast fading改为per-link
%   - 引入PRB overlap干扰
%   - 输出interference给KPI
%   - 保持强耦合竞争结构
%

    properties

        % Pathloss
        pathlossExp = 3.5
        shadowingStd_dB = 6
        shadowCorrDist_m = 50

        % Noise
        noiseFigure_dB = 7
        temperature_K  = 290

        % Load
        interfMinLoad = 0.05
        loadSmoothFactor = 0.8

        % Coupling
        kTxExp   = 0.35
        kBwExp   = 0.8
        kLoadExp = 1.5
        edgeBoost = 1.5

        % SINR compression
        sinrCompressThreshold_dB = 25
        sinrCompressSlope = 0.6

        % Fading
        fastFadeSigmaLow_dB  = 1
        fastFadeSigmaHigh_dB = 3
        speedThreshold_mps   = 8

        % Internal
        shadowField
        smoothedLoad
        lastUEPos
    end

    methods

        function initialize(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            obj.shadowField  = obj.shadowingStd_dB * randn(numUE,numCell);
            obj.smoothedLoad = ones(numCell,1) * 0.5;
            obj.lastUEPos    = ctx.uePos;
        end

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            if isempty(obj.shadowField)
                obj.initialize(ctx);
            end

            gNB = ctx.scenario.topology.gNBPos;

            %% =========================================
            % 1️⃣ Shadow update
            %% =========================================
            deltaPos = vecnorm(ctx.uePos - obj.lastUEPos,2,2);
            obj.lastUEPos = ctx.uePos;

            for u = 1:numUE
                corr = exp(-deltaPos(u)/obj.shadowCorrDist_m);
                newShadow = obj.shadowingStd_dB * randn(1,numCell);
                obj.shadowField(u,:) = ...
                    corr * obj.shadowField(u,:) + ...
                    sqrt(max(1-corr^2,0))*newShadow;
            end

            %% =========================================
            % 2️⃣ Fast fading (PER-LINK 修复)
            %% =========================================
            v = deltaPos / max(ctx.dt,1e-12);
            sigma = obj.fastFadeSigmaLow_dB * ones(numUE,1);
            sigma(v >= obj.speedThreshold_mps) = obj.fastFadeSigmaHigh_dB;

            fastFade = randn(numUE,numCell) .* sigma;

            %% =========================================
            % 3️⃣ Load smoothing
            %% =========================================
            prbTotal = ctx.numPRBPerCell(:);
            prbUsed  = ctx.lastPRBUsedPerCell_slot(:);

            instLoad = prbUsed ./ max(prbTotal,1);
            instLoad = min(max(instLoad,obj.interfMinLoad),1);

            obj.smoothedLoad = ...
                obj.loadSmoothFactor * obj.smoothedLoad + ...
                (1-obj.loadSmoothFactor)*instLoad;

            load = obj.smoothedLoad;

            %% =========================================
            % 4️⃣ RSRP计算（加入Beam）
            %% =========================================
            txPower = min(max(ctx.txPowerCell_dBm(:),-50),80);

            rsrp = zeros(numUE,numCell);

            for c=1:numCell

                d = vecnorm(ctx.uePos - gNB(c,:),2,2);
                d = max(d,1);
                pl = 10*obj.pathlossExp*log10(d);

                beamGain = 0;
                if isfield(ctx.tmp,'beamGain_dB')
                    beamGain = ctx.tmp.beamGain_dB(:,c);
                end

                rsrp(:,c) = txPower(c) ...
                            - pl ...
                            + obj.shadowField(:,c) ...
                            + fastFade(:,c) ...
                            + beamGain;
            end

            ctx.rsrp_dBm = rsrp;

            %% =========================================
            % 5️⃣ 干扰耦合
            %% =========================================

            BWcell = max(ctx.bandwidthHzPerCell(:),1e3);

            txRef = median(txPower);
            txPart = (10.^((txPower - txRef)/10)).^obj.kTxExp;

            bwRef = median(BWcell);
            bwPart = (BWcell/bwRef).^obj.kBwExp;

            loadPart = load.^obj.kLoadExp;

            interfScale = txPart .* bwPart .* loadPart;

            %% =========================================
            % 6️⃣ Noise
            %% =========================================
            kB = 1.38e-23;
            noiseW = kB * obj.temperature_K .* BWcell;
            noiseW = noiseW * 10^(obj.noiseFigure_dB/10);
            noiseW = max(noiseW,1e-20);

            %% =========================================
            % 7️⃣ SINR计算 + overlap
            %% =========================================
            sinr_dB = zeros(numUE,1);
            interf_dBm = zeros(numUE,1);

            for u=1:numUE

                s = ctx.servingCell(u);
                if s<1 || s>numCell
                    s=1;
                end

                sigW = 10.^((rsrp(u,s)-30)/10);

                interfW = 0;

                for c=1:numCell
                    if c==s
                        continue;
                    end

                    pW = 10.^((rsrp(u,c)-30)/10);

                    % PRB overlap
                    overlap = min(load(s), load(c));

                    % 边缘UE增强
                    if rsrp(u,s) < median(rsrp(u,:))
                        edgeFactor = obj.edgeBoost;
                    else
                        edgeFactor = 1;
                    end

                    interfW = interfW + ...
                        pW * interfScale(c) * overlap * edgeFactor;
                end

                sinrW = sigW / (interfW + noiseW(s) + 1e-15);

                sinr = 10*log10(max(sinrW,1e-12));

                if sinr > obj.sinrCompressThreshold_dB
                    excess = sinr - obj.sinrCompressThreshold_dB;
                    sinr = obj.sinrCompressThreshold_dB + ...
                           obj.sinrCompressSlope * excess;
                end

                sinr_dB(u) = sinr;

                interf_dBm(u) = 10*log10(max(interfW,1e-15)) + 30;
            end

            ctx.sinr_dB = sinr_dB;
            ctx.tmp.meanSinr_dB = mean(sinr_dB);

            % 👉 输出给KPI
            if ~isfield(ctx.tmp,'channel')
                ctx.tmp.channel = struct();
            end
            ctx.tmp.channel.interference_dBm = interf_dBm;

            %% =========================================
            % Debug
            %% =========================================
            ctx = obj.writeDebugTrace(ctx, txPower, BWcell, load, interfScale);

            if obj.shouldPrint(ctx)
                obj.printDebug(ctx);
            end
        end
    end

    methods (Access=private)

        function ctx = writeDebugTrace(~, ctx, txPower, BWcell, load, interfScale)

            if ~isfield(ctx.tmp,'debug')
                ctx.tmp.debug = struct();
            end
            if ~isfield(ctx.tmp.debug,'trace')
                ctx.tmp.debug.trace = struct();
            end

            tr = struct();
            tr.slot = ctx.slot;

            tr.cell.txPower = txPower;
            tr.cell.bandwidth = BWcell;
            tr.cell.load = load;
            tr.cell.interfScale = interfScale;

            tr.ue.meanSinr = mean(ctx.sinr_dB);
            tr.ue.minSinr  = min(ctx.sinr_dB);
            tr.ue.maxSinr  = max(ctx.sinr_dB);

            ctx.tmp.debug.trace.radio = tr;
        end

        function tf = shouldPrint(~, ctx)

            tf = false;
            if ~isfield(ctx.cfg,'debug'), return; end
            if ~ctx.cfg.debug.enable, return; end

            every = 100;
            if isfield(ctx.cfg.debug,'every')
                every = ctx.cfg.debug.every;
            end

            if mod(ctx.slot,every)~=0
                return;
            end

            if isfield(ctx.cfg.debug,'modules')
                ms = string(ctx.cfg.debug.modules);
                if ~any(ms=="radio") && ~any(ms=="all")
                    return;
                end
            end

            tf = true;
        end

        function printDebug(~, ctx)

            tr = ctx.tmp.debug.trace.radio;

            fprintf('[DEBUG][slot=%d][radio] meanSINR=%.2f dB min=%.2f max=%.2f\n', ...
                tr.slot, tr.ue.meanSinr, tr.ue.minSinr, tr.ue.maxSinr);
        end
    end
end