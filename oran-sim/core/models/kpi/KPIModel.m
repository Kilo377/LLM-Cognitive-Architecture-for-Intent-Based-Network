classdef KPIModel
%KPIMODEL v4 (Clean architecture + debug-safe)
%
% Rules:
%   - NEVER write ctx.state directly
%   - ONLY write ctx.tmp.kpi
%   - Episode accumulators come from ctx.acc*
%   - Slot metrics come from ctx.tmp.*
%   - RanContext.updateStateBus() publishes final state

    properties
        avgPacketBitsForDropRatio = 12000
        debugFirstSlots = 3
    end

    methods

        function obj = KPIModel()
        end

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            if ~isfield(ctx.tmp,'kpi') || isempty(ctx.tmp.kpi)
                ctx.tmp.kpi = struct();
            end

            %% =====================================================
            % 1) Time base
            %% =====================================================
            t_s = double(ctx.slot) * double(ctx.dt);
            if t_s <= 0
                t_s = eps;
            end

            %% =====================================================
            % 2) Throughput (Episode-level)
            %% =====================================================
            thrBitPerUE = ctx.accThroughputBitPerUE(:);
            thrBitTotal = sum(thrBitPerUE);

            thr_bps_total  = thrBitTotal / t_s;
            thr_Mbps_total = thr_bps_total / 1e6;

            ctx.tmp.kpi.throughputBitPerUE   = thrBitPerUE;
            ctx.tmp.kpi.throughput_bps_total = thr_bps_total;
            ctx.tmp.kpi.throughput_Mbps_total = thr_Mbps_total;

            ctx.tmp.kpi.jainFairness = localJain(thrBitPerUE);

            %% =====================================================
            % 3) Energy (Episode-level)
            %% =====================================================
            eJPerCell = ctx.accEnergyJPerCell(:);
            eJ_total  = sum(eJPerCell);

            ctx.tmp.kpi.energyJPerCell = eJPerCell;
            ctx.tmp.kpi.energy_J_total = eJ_total;

            if eJ_total > 0
                ctx.tmp.kpi.energy_eff_bit_per_J = thrBitTotal / eJ_total;
            else
                ctx.tmp.kpi.energy_eff_bit_per_J = 0;
            end

            %% =====================================================
            % 4) PRB utilization (Episode-level)
            %% =====================================================
            prbUsed  = ctx.accPRBUsedPerCell(:);
            prbTotal = ctx.accPRBTotalPerCell(:);

            prbTotalSafe = prbTotal;
            prbTotalSafe(prbTotalSafe <= 0) = 1;

            prbUtilPerCell = prbUsed ./ prbTotalSafe;
            prbUtilPerCell = min(max(prbUtilPerCell,0),1);

            ctx.tmp.kpi.prbUsedPerCell  = prbUsed;
            ctx.tmp.kpi.prbTotalPerCell = prbTotal;
            ctx.tmp.kpi.prbUtilPerCell  = prbUtilPerCell;
            ctx.tmp.kpi.prbUtilMean     = mean(prbUtilPerCell);

            %% =====================================================
            % 5) PHY quality (Slot-level instantaneous)
            %% =====================================================
            if numel(ctx.sinr_dB) == numUE
                ctx.tmp.kpi.meanSINR_dB = mean(ctx.sinr_dB);
            else
                ctx.tmp.kpi.meanSINR_dB = 0;
            end

            if isfield(ctx.tmp,'lastMCSPerUE')
                v = ctx.tmp.lastMCSPerUE(:);
                if numel(v)==numUE
                    ctx.tmp.kpi.meanMCS = mean(v);
                else
                    ctx.tmp.kpi.meanMCS = 0;
                end
            else
                ctx.tmp.kpi.meanMCS = 0;
            end

            if isfield(ctx.tmp,'lastBLERPerUE')
                v = ctx.tmp.lastBLERPerUE(:);
                if numel(v)==numUE
                    ctx.tmp.kpi.meanBLER = mean(v);
                else
                    ctx.tmp.kpi.meanBLER = 0;
                end
            else
                ctx.tmp.kpi.meanBLER = 0;
            end

            %% =====================================================
            % 6) Drop statistics
            %% =====================================================
            dropTotal = double(ctx.accDroppedTotal);
            dropURLLC = double(ctx.accDroppedURLLC);

            ctx.tmp.kpi.dropTotal = dropTotal;
            ctx.tmp.kpi.dropURLLC = dropURLLC;

            deliveredPktsApprox = thrBitTotal / max(obj.avgPacketBitsForDropRatio,1);

            denom = dropTotal + deliveredPktsApprox;
            if denom <= 0
                dropRatio = 0;
            else
                dropRatio = dropTotal / denom;
            end

            ctx.tmp.kpi.dropRatio = dropRatio;

            %% =====================================================
            % 7) Mobility events (Episode-level)
            %% =====================================================
            ctx.tmp.kpi.handoverCount  = ctx.accHOCount;
            ctx.tmp.kpi.pingPongCount  = ctx.accPingPongCount;
            ctx.tmp.kpi.rlfCount       = ctx.accRLFCount;

            %% =====================================================
            % 8) Slot-level PRB usage (optional)
            %% =====================================================
            if isfield(ctx.tmp,'lastPRBUsedPerCell')
                ctx.tmp.kpi.lastPrbUsedSlot = ctx.tmp.lastPRBUsedPerCell(:);
            else
                ctx.tmp.kpi.lastPrbUsedSlot = zeros(numCell,1);
            end

            %% =====================================================
            % 9) Debug
            %% =====================================================
            if ctx.slot <= obj.debugFirstSlots
                fprintf('[KPI] slot=%d Thr=%.2f Mbps, Energy=%.2f J, DropR=%.4f\n', ...
                    ctx.slot, thr_Mbps_total, eJ_total, dropRatio);
            end
        end
    end
end


%% =============================================================
% Local helper
%% =============================================================
function j = localJain(x)
x = double(x(:));
if isempty(x)
    j = 0;
    return;
end
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
