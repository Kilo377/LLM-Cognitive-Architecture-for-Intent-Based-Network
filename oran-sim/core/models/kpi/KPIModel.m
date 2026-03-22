classdef KPIModel
% KPIMODEL v6.0 (Intent-Oriented & Physically Consistent)
%
% 分层KPI:
%   1. Capacity
%   2. Reliability
%   3. Efficiency
%   4. Resource pressure
%   5. Stability
%
% 只写 ctx.tmp.kpi
%

    properties
        avgPacketBitsForDropRatio = 12000
        debugFirstSlots = 3
    end

    methods

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            if ~isfield(ctx.tmp,'kpi')
                ctx.tmp.kpi = struct();
            end

            t_s = max(double(ctx.slot) * double(ctx.dt), eps);

            %% =====================================================
            % 1️⃣ CAPACITY
            %% =====================================================
            thrBitPerUE = ctx.accThroughputBitPerUE(:);
            thrBitTotal = sum(thrBitPerUE);

            thr_Mbps_total = (thrBitTotal / t_s) / 1e6;

            ctx.tmp.kpi.capacity.throughput_Mbps_total = thr_Mbps_total;
            ctx.tmp.kpi.capacity.jainFairness = localJain(thrBitPerUE);
            ctx.tmp.kpi.capacity.top10Share = localTopShare(thrBitPerUE, 0.10);

            %% =====================================================
            % 1.1) QoS CAPACITY
            %% =====================================================
            ctx.tmp.kpi.qos = struct();
            ctx.tmp.kpi.qos.throughput_Mbps = localQosThroughput(ctx, t_s);

            %% =====================================================
            % 2️⃣ RELIABILITY
            %% =====================================================
            if isfield(ctx.tmp,'lastBLERPerUE')
                meanBLER = mean(ctx.tmp.lastBLERPerUE(:));
            else
                meanBLER = 0;
            end

            ctx.tmp.kpi.reliability.meanBLER = meanBLER;
            ctx.tmp.kpi.reliability.rlfCount = ctx.accRLFCount;
            ctx.tmp.kpi.reliability.dropRatio = computeDrop(ctx, obj, thrBitTotal);

            %% =====================================================
            % 2.1) QoS RELIABILITY
            %% =====================================================
            ctx.tmp.kpi.qos.dropRatio = localQosDrop(ctx, obj);

            %% =====================================================
            % 3️⃣ EFFICIENCY
            %% =====================================================
            eJ_total = sum(ctx.accEnergyJPerCell(:));

            ctx.tmp.kpi.efficiency.energy_J_total = eJ_total;

            if eJ_total > 0
                ctx.tmp.kpi.efficiency.bitPerJ = thrBitTotal / eJ_total;
            else
                ctx.tmp.kpi.efficiency.bitPerJ = 0;
            end

            %% =====================================================
            % 4️⃣ RESOURCE PRESSURE
            %% =====================================================
            prbUsed  = ctx.accPRBUsedPerCell(:);
            prbTotal = ctx.accPRBTotalPerCell(:);
            prbUtil = min(max(prbUsed ./ max(prbTotal,1),0),1);

            ctx.tmp.kpi.resource.prbUtilMean = mean(prbUtil);
            ctx.tmp.kpi.resource.prbImbalance = std(prbUtil);

            % Interference
            if isfield(ctx.tmp,'channel') && ...
               isfield(ctx.tmp.channel,'interference_dBm')

                interf = ctx.tmp.channel.interference_dBm;
                interf = interf(isfinite(interf));

                if ~isempty(interf)
                    ctx.tmp.kpi.resource.meanInterference_dBm = mean(interf);
                    ctx.tmp.kpi.resource.interfStd = std(interf);
                else
                    ctx.tmp.kpi.resource.meanInterference_dBm = -inf;
                    ctx.tmp.kpi.resource.interfStd = 0;
                end
            else
                ctx.tmp.kpi.resource.meanInterference_dBm = -inf;
                ctx.tmp.kpi.resource.interfStd = 0;
            end

            %% =====================================================
            % 5️⃣ PHY DISTRIBUTION
            %% =====================================================
            if numel(ctx.sinr_dB) == numUE

                sinr = ctx.sinr_dB(:);

                ctx.tmp.kpi.phy.meanSINR_dB = mean(sinr);
                ctx.tmp.kpi.phy.p10SINR_dB  = prctile(sinr,10);
                ctx.tmp.kpi.phy.p50SINR_dB  = prctile(sinr,50);
                ctx.tmp.kpi.phy.p90SINR_dB  = prctile(sinr,90);
                ctx.tmp.kpi.phy.sinrStd     = std(sinr);
            else
                ctx.tmp.kpi.phy.meanSINR_dB = 0;
                ctx.tmp.kpi.phy.p10SINR_dB  = 0;
                ctx.tmp.kpi.phy.p50SINR_dB  = 0;
                ctx.tmp.kpi.phy.p90SINR_dB  = 0;
                ctx.tmp.kpi.phy.sinrStd     = 0;
            end

            %% =====================================================
            % 6️⃣ STABILITY
            %% =====================================================
            ctx.tmp.kpi.stability.handoverCount = ctx.accHOCount;
            ctx.tmp.kpi.stability.pingPongCount = ctx.accPingPongCount;

            %% =====================================================
            % 6.1) INSTANT KPI (per-slot)
            %% =====================================================
            ctx.tmp.kpi.instant = struct();

            if isfield(ctx.tmp,'lastServedBitsPerUE')
                instBits = sum(double(ctx.tmp.lastServedBitsPerUE(:)));
                ctx.tmp.kpi.instant.throughput_Mbps = (instBits / max(double(ctx.dt), eps)) / 1e6;
            else
                ctx.tmp.kpi.instant.throughput_Mbps = 0;
            end

            instDropRatio = 0;
            if isprop(ctx,'scenario') && isfield(ctx.scenario,'traffic') && isfield(ctx.scenario.traffic,'model')
                tm = ctx.scenario.traffic.model;
                if isprop(tm,'lastDropThisSlot') && ~isempty(tm.lastDropThisSlot)
                    droppedBits = double(tm.lastDropThisSlot.bitsTotal);
                    denom = droppedBits;
                    if isfield(ctx.tmp,'lastServedBitsPerUE')
                        denom = denom + sum(double(ctx.tmp.lastServedBitsPerUE(:)));
                    end
                    if denom > 0
                        instDropRatio = droppedBits / denom;
                    end
                end
            end
            ctx.tmp.kpi.instant.dropRatio = instDropRatio;

            if isfield(ctx.tmp,'lastBLERPerUE')
                ctx.tmp.kpi.instant.meanBLER = mean(double(ctx.tmp.lastBLERPerUE(:)));
            else
                ctx.tmp.kpi.instant.meanBLER = 0;
            end

            if isprop(ctx,'sinr_dB') && ~isempty(ctx.sinr_dB)
                ctx.tmp.kpi.instant.meanSINR_dB = mean(double(ctx.sinr_dB(:)));
            else
                ctx.tmp.kpi.instant.meanSINR_dB = 0;
            end

            instPrbUtil = 0;
            if isprop(ctx,'lastPRBUsedPerCell_slot') && isprop(ctx,'numPRBPerCell')
                instPrbUtil = mean(double(ctx.lastPRBUsedPerCell_slot(:)) ./ max(double(ctx.numPRBPerCell(:)),1));
            end
            ctx.tmp.kpi.instant.prbUtilMean = instPrbUtil;

            %% =====================================================
            % 7️⃣ PHYSICAL CONGESTION INDEX
            %% =====================================================
            % 基于物理逻辑构建，不是经验拼接

            loadIndex = ctx.tmp.kpi.resource.prbUtilMean;
            blerIndex = ctx.tmp.kpi.reliability.meanBLER;
            sinrIndex = max(0, -ctx.tmp.kpi.phy.p10SINR_dB / 10);

            congestion = ...
                0.5 * loadIndex + ...
                0.3 * blerIndex + ...
                0.2 * sinrIndex;

            ctx.tmp.kpi.system.congestionIndex = congestion;
  



            

            % =====================================================
            % PATCH2: kernel observability (ctx-only)
            % =====================================================
            if isfield(ctx,'cfg') && isfield(ctx.cfg,'debug') && ...
               isfield(ctx.cfg.debug,'enable') && ctx.cfg.debug.enable
            
                every = 100;
                if isfield(ctx.cfg.debug,'every') && isnumeric(ctx.cfg.debug.every) && ctx.cfg.debug.every >= 1
                    every = round(ctx.cfg.debug.every);
                end
            
                if mod(ctx.slot, every) == 0
            
                    % buffer bits (from state bus)
                    bufTot = 0;
                    if isfield(ctx,'bufferBitsPerUE')
                        bufTot = sum(double(ctx.bufferBitsPerUE(:)));
                    elseif isfield(ctx,'tmp') && isfield(ctx.tmp,'traffic') && isfield(ctx.tmp.traffic,'queueBitsPerUE')
                        bufTot = sum(double(ctx.tmp.traffic.queueBitsPerUE(:)));
                    end
            
                    % PRB util (instant, not accumulated)
                    prbUtilMean = 0;
                    if isfield(ctx,'numPRBPerCell') && isfield(ctx,'lastPRBUsedPerCell_slot')
                        prbUtilMean = mean(double(ctx.lastPRBUsedPerCell_slot(:)) ./ max(double(ctx.numPRBPerCell(:)),1));
                    end
            
                    % MCS mean
                    mcsMean = 0;
                    if isfield(ctx,'mcsPerUE')
                        mcsMean = mean(double(ctx.mcsPerUE(:)));
                    elseif isfield(ctx,'tmp') && isfield(ctx.tmp,'lastMCSPerUE')
                        mcsMean = mean(double(ctx.tmp.lastMCSPerUE(:)));
                    end
            
                    % runtime knobs snapshot
                    txMean = 0;
                    if isfield(ctx,'txPowerCell_dBm')
                        txMean = mean(double(ctx.txPowerCell_dBm(:)));
                    end
            
                    prbMean = 0;
                    if isfield(ctx,'numPRBPerCell')
                        prbMean = mean(double(ctx.numPRBPerCell(:)));
                    end
            
                    fprintf('[PATCH2][slot=%d] bufTot=%.2e bits | prbUtilMean=%.2f | mcsMean=%.2f | txMean=%.2f dBm | prbMean=%.1f\n', ...
                        ctx.slot, bufTot, prbUtilMean, mcsMean, txMean, prbMean);
                end
            end

            %% =====================================================
            % Debug
            %% =====================================================
            if ctx.slot <= obj.debugFirstSlots
                fprintf('[KPI] slot=%d Thr=%.2f Mbps | BLER=%.3f | Cong=%.3f\n', ...
                    ctx.slot, thr_Mbps_total, meanBLER, congestion);
            end
        end
    end
end


%% =============================================================
function dropRatio = computeDrop(ctx, obj, thrBitTotal)

dropTotal = double(ctx.accDroppedTotal);

deliveredPktsApprox = thrBitTotal / max(obj.avgPacketBitsForDropRatio,1);
denom = dropTotal + deliveredPktsApprox;

if denom > 0
    dropRatio = dropTotal / denom;
else
    dropRatio = 0;
end
end


function j = localJain(x)
x = double(x(:));
sx = sum(x);
sx2 = sum(x.^2);
n = numel(x);
if sx2 <= 0
    j = 0;
else
    j = (sx^2) / (n * sx2);
end
j = min(max(j,0),1);
end

function out = localQosThroughput(ctx, t_s)

names = ["eMBB","URLLC","mMTC"];
bits = zeros(3,1);
if isprop(ctx,'accQosServedBits') && numel(ctx.accQosServedBits) == 3
    bits = ctx.accQosServedBits(:);
end

out = struct();
for i = 1:3
    out.(names(i)) = (bits(i) / max(t_s, eps)) / 1e6;
end
end

function s = localTopShare(x, ratio)
x = double(x(:));
total = sum(x);
if total <= 0
    s = 0;
    return;
end
n = numel(x);
k = max(1, round(n * ratio));
x = sort(x, 'descend');
s = sum(x(1:k)) / total;
end

function out = localQosDrop(ctx, obj)

names = ["eMBB","URLLC","mMTC"];
dropCnt = zeros(3,1);
servedBits = zeros(3,1);

if isprop(ctx,'accQosDroppedCount') && numel(ctx.accQosDroppedCount) == 3
    dropCnt = ctx.accQosDroppedCount(:);
end

if isprop(ctx,'accQosServedBits') && numel(ctx.accQosServedBits) == 3
    servedBits = ctx.accQosServedBits(:);
end

out = struct();
for i = 1:3
    deliveredPktsApprox = servedBits(i) / max(obj.avgPacketBitsForDropRatio,1);
    denom = dropCnt(i) + deliveredPktsApprox;
    if denom > 0
        out.(names(i)) = dropCnt(i) / denom;
    else
        out.(names(i)) = 0;
    end
end
end
