classdef RadioModel < handle
% RADIOMODEL v8.0 (High-Coupling Competitive Version)
%
% 强化干扰竞争模型：
%   1) 功率放大干扰采用指数级映射
%   2) 带宽影响通过资源竞争 + 噪声同时作用
%   3) 负载对干扰为超线性
%   4) 加入边缘UE干扰放大
%   5) 加入SINR压缩，避免无限增长
%
% Debug接口保持统一：
%   ctx.tmp.debug.trace.radio
%

    properties

        % Pathloss
        pathlossExp = 3.5
        shadowingStd_dB = 6
        shadowCorrDist_m = 50

        % Noise
        noiseFigure_dB = 7
        temperature_K  = 290

        % Load model
        interfMinLoad = 0.05
        loadSmoothFactor = 0.8

        % ===== 强耦合参数 =====
        kTxExp      = 0.35   % 功率指数耦合
        kBwExp      = 0.8    % 带宽指数耦合
        kLoadExp    = 1.8    % 负载超线性
        edgeBoost   = 1.6    % 边缘UE干扰放大
        sinrCompressThreshold_dB = 25
        sinrCompressSlope        = 0.6

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

            obj.shadowField  = obj.shadowingStd_dB * randn(numUE, numCell);
            obj.smoothedLoad = ones(numCell,1) * 0.5;
            obj.lastUEPos    = ctx.uePos;
        end

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            if isempty(obj.shadowField)
                obj.initialize(ctx);
            end

            % =============================
            % gNB position
            % =============================
            gNB = ctx.scenario.topology.gNBPos;

            % =============================
            % Shadow update
            % =============================
            deltaPos = vecnorm(ctx.uePos - obj.lastUEPos,2,2);
            obj.lastUEPos = ctx.uePos;

            for u = 1:numUE
                corr = exp(-deltaPos(u)/obj.shadowCorrDist_m);
                newShadow = obj.shadowingStd_dB * randn(1,numCell);
                obj.shadowField(u,:) = ...
                    corr * obj.shadowField(u,:) + ...
                    sqrt(max(1-corr^2,0))*newShadow;
            end

            % =============================
            % Tx power
            % =============================
            txPower = ctx.txPowerCell_dBm(:);
            txPower = min(max(txPower,-50),80);

            % =============================
            % PRB load
            % =============================
            prbTotal = ctx.numPRBPerCell(:);
            prbUsed  = ctx.lastPRBUsedPerCell_slot(:);

            instLoad = prbUsed ./ max(prbTotal,1);
            instLoad = max(instLoad, obj.interfMinLoad);
            instLoad = min(instLoad,1);

            obj.smoothedLoad = ...
                obj.loadSmoothFactor * obj.smoothedLoad + ...
                (1-obj.loadSmoothFactor)*instLoad;

            load = obj.smoothedLoad;

            % =============================
            % Bandwidth
            % =============================
            BWcell = ctx.bandwidthHzPerCell(:);
            BWcell = max(BWcell,1e3);

            % =============================
            % Noise
            % =============================
            kB = 1.38e-23;
            noiseW = kB*obj.temperature_K .* BWcell;
            noiseW = noiseW * 10^(obj.noiseFigure_dB/10);
            noiseW = max(noiseW,1e-20);

            % =============================
            % Fast fading
            % =============================
            v = deltaPos / max(ctx.dt,1e-12);
            sigmaFF = obj.fastFadeSigmaLow_dB * ones(numUE,1);
            sigmaFF(v >= obj.speedThreshold_mps) = obj.fastFadeSigmaHigh_dB;
            fastFade = sigmaFF .* randn(numUE,1);

            % =============================
            % RSRP
            % =============================
            rsrp = zeros(numUE,numCell);

            for c=1:numCell
                d = vecnorm(ctx.uePos - gNB(c,:),2,2);
                d = max(d,1);
                pl = 10*obj.pathlossExp*log10(d);

                rsrp(:,c) = txPower(c) - pl + ...
                            obj.shadowField(:,c) + ...
                            fastFade;
            end

            ctx.rsrp_dBm = rsrp;

            % =============================
            % 干扰耦合构建
            % =============================

            % 1️⃣ 功率指数耦合
            txRef = median(txPower);
            txRatio = 10.^((txPower - txRef)/10);
            txPart = txRatio .^ obj.kTxExp;

            % 2️⃣ 带宽耦合
            bwRef = median(BWcell);
            bwRatio = BWcell / bwRef;
            bwPart = bwRatio .^ obj.kBwExp;

            % 3️⃣ 负载超线性
            loadPart = load .^ obj.kLoadExp;

            interfScale = txPart .* bwPart .* loadPart;

            % =============================
            % SINR计算
            % =============================
            sinr_dB = zeros(numUE,1);

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

                    % 边缘UE增强干扰
                    if rsrp(u,s) < median(rsrp(u,:))
                        edgeFactor = obj.edgeBoost;
                    else
                        edgeFactor = 1;
                    end

                    interfW = interfW + pW * interfScale(c) * edgeFactor;
                end

                sinrW = sigW / (interfW + noiseW(s) + 1e-15);
                sinr = 10*log10(max(sinrW,1e-12));

                % 4️⃣ SINR压缩
                if sinr > obj.sinrCompressThreshold_dB
                    excess = sinr - obj.sinrCompressThreshold_dB;
                    sinr = obj.sinrCompressThreshold_dB + ...
                           obj.sinrCompressSlope * excess;
                end

                sinr_dB(u) = sinr;
            end

            ctx.sinr_dB = sinr_dB;
            ctx.tmp.meanSinr_dB = mean(sinr_dB);

            % =============================
            % Debug trace
            % =============================
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

            fprintf('[DEBUG][slot=%d][radio] meanSINR=%.2f dB  min=%.2f  max=%.2f\n', ...
                tr.slot, tr.ue.meanSinr, tr.ue.minSinr, tr.ue.maxSinr);

            for c=1:numel(tr.cell.txPower)
                fprintf('  cell=%d tx=%.1f dBm bw=%.1f MHz load=%.2f interfScale=%.3f\n', ...
                    c, ...
                    tr.cell.txPower(c), ...
                    tr.cell.bandwidth(c)/1e6, ...
                    tr.cell.load(c), ...
                    tr.cell.interfScale(c));
            end
        end
    end
end
