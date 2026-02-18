classdef KPIModel
%KPIMODEL v3
%
% Goal:
%   Compute and publish ALL network KPI in core (not in run scripts).
%
% Reads (from ctx):
%   ctx.slot, ctx.dt
%   ctx.accThroughputBitPerUE
%   ctx.accDroppedTotal, ctx.accDroppedURLLC
%   ctx.accEnergyJPerCell
%   ctx.accHOCount, ctx.accPingPongCount, ctx.accRLFCount
%   ctx.accPRBUsedPerCell, ctx.accPRBTotalPerCell
%   ctx.sinr_dB
%   ctx.tmp.lastMCSPerUE
%   ctx.tmp.lastBLERPerUE
%   ctx.tmp.lastServedBitsPerUE
%
% Writes (to ctx.tmp.kpi AND ctx.state.kpi via ctx.updateStateBus()):
%   tmp.kpi.throughput_bps_total
%   tmp.kpi.throughput_Mbps_total
%   tmp.kpi.throughputBitPerUE
%   tmp.kpi.jainFairness
%   tmp.kpi.energy_J_total
%   tmp.kpi.energy_eff_bit_per_J
%   tmp.kpi.meanSINR_dB
%   tmp.kpi.meanMCS
%   tmp.kpi.meanBLER
%   tmp.kpi.dropTotal
%   tmp.kpi.dropURLLC
%   tmp.kpi.dropRatio
%   tmp.kpi.handoverCount
%   tmp.kpi.pingPongCount
%   tmp.kpi.rlfCount
%   tmp.kpi.prbUtilMean
%   tmp.kpi.prbUtilPerCell
%   tmp.kpi.prbUsedPerCell
%   tmp.kpi.prbTotalPerCell
%
% Notes:
%   - This model is deterministic given ctx data (except traffic/phy randomness upstream).
%   - "dropRatio" here is defined as:
%         dropTotal / max(dropTotal + deliveredPktsApprox, 1)
%     Since we may not have per-packet delivery counters, we provide two versions:
%       A) dropRatio_bitsApprox : using throughput bits / avgPacketBits
%       B) dropRatio_pktsIfAvailable : if traffic model exposes counters, use them
%   - If your traffic model has exact generated/delivered packet counts,
%     add hooks in section [Drop ratio] below.

    properties
        avgPacketBitsForDropRatio = 12000; % ~1500 bytes. Used only if no packet counters.
    end

    methods
        function obj = KPIModel()
        end

        function ctx = step(obj, ctx)

            if ~isfield(ctx.tmp,'kpi') || isempty(ctx.tmp.kpi)
                ctx.tmp.kpi = struct();
            end

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            %% -------------------------------
            % 1) Time base
            %% -------------------------------
            t_s = double(ctx.slot) * double(ctx.dt);
            if t_s <= 0
                t_s = eps;
            end

            %% -------------------------------
            % 2) Throughput
            %% -------------------------------
            thrBitPerUE = ctx.accThroughputBitPerUE(:);
            thrBitTotal = sum(thrBitPerUE);

            thr_bps_total  = thrBitTotal / t_s;
            thr_Mbps_total = thr_bps_total / 1e6;

            ctx.tmp.kpi.throughputBitPerUE   = thrBitPerUE;
            ctx.tmp.kpi.throughput_bps_total = thr_bps_total;
            ctx.tmp.kpi.throughput_Mbps_total = thr_Mbps_total;

            %% Jain fairness over UE throughput
            ctx.tmp.kpi.jainFairness = localJain(thrBitPerUE);

            %% -------------------------------
            % 3) Energy
            %% -------------------------------
            eJPerCell = ctx.accEnergyJPerCell(:);
            eJ_total  = sum(eJPerCell);

            ctx.tmp.kpi.energyJPerCell = eJPerCell;
            ctx.tmp.kpi.energy_J_total = eJ_total;

            if eJ_total > 0
                ctx.tmp.kpi.energy_eff_bit_per_J = thrBitTotal / eJ_total;
            else
                ctx.tmp.kpi.energy_eff_bit_per_J = 0;
            end

            %% -------------------------------
            % 4) PRB utilization
            %% -------------------------------
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

            %% -------------------------------
            % 5) PHY quality KPIs (mean SINR/MCS/BLER)
            %% -------------------------------
            % SINR always in ctx
            if ~isempty(ctx.sinr_dB) && numel(ctx.sinr_dB) == numUE
                ctx.tmp.kpi.meanSINR_dB = mean(ctx.sinr_dB);
            else
                ctx.tmp.kpi.meanSINR_dB = 0;
            end

            % MCS/BLER are in tmp from PhyServiceModel
            if isfield(ctx.tmp,'lastMCSPerUE') && numel(ctx.tmp.lastMCSPerUE) == numUE
                ctx.tmp.kpi.meanMCS = mean(ctx.tmp.lastMCSPerUE);
            else
                ctx.tmp.kpi.meanMCS = 0;
            end

            if isfield(ctx.tmp,'lastBLERPerUE') && numel(ctx.tmp.lastBLERPerUE) == numUE
                ctx.tmp.kpi.meanBLER = mean(ctx.tmp.lastBLERPerUE);
            else
                ctx.tmp.kpi.meanBLER = 0;
            end

            %% -------------------------------
            % 6) Drops
            %% -------------------------------
            dropTotal = double(ctx.accDroppedTotal);
            dropURLLC = double(ctx.accDroppedURLLC);

            ctx.tmp.kpi.dropTotal = dropTotal;
            ctx.tmp.kpi.dropURLLC = dropURLLC;

            % Drop ratio:
            % Try to use traffic model counters if you expose them.
            % Fallback: estimate delivered packet count by throughput bits / avgPacketBits.
            deliveredPktsApprox = thrBitTotal / max(obj.avgPacketBitsForDropRatio,1);

            denom = dropTotal + deliveredPktsApprox;
            if denom <= 0
                dropRatio = 0;
            else
                dropRatio = dropTotal / denom;
            end

            ctx.tmp.kpi.dropRatio = dropRatio;

            %% -------------------------------
            % 7) Mobility events
            %% -------------------------------
            ctx.tmp.kpi.handoverCount  = double(ctx.accHOCount);
            ctx.tmp.kpi.pingPongCount  = double(ctx.accPingPongCount);
            ctx.tmp.kpi.rlfCount       = double(ctx.accRLFCount);

            %% -------------------------------
            % 8) Per-cell traffic share (optional)
            %% -------------------------------
            % If you later export per-cell served bits, you can add it here.
            % For now, keep placeholder.
            ctx.tmp.kpi.throughputSharePerCell = zeros(numCell,1);

            %% -------------------------------
            % 9) Sync to state bus if available
            %% -------------------------------
            % RanContext.updateStateBus() currently reads:
            %   s.kpi.throughputBitPerUE
            %   s.kpi.dropTotal / dropURLLC
            %   s.kpi.handoverCount / rlfCount
            %   s.kpi.energyJPerCell / energySignal_J_total
            %   s.kpi.prbUtilPerCell
            %
            % We also want to expose derived KPIs. The simplest way:
            %   add fields in state.kpi (RanStateBus.init) OR store them under state.tmp-like.
            %
            % Here we write to ctx.state.kpi if fields exist.
            if isfield(ctx,'state') && isfield(ctx.state,'kpi')

                % Always-present fields
                ctx.state.kpi.throughputBitPerUE = thrBitPerUE;
                ctx.state.kpi.dropTotal          = dropTotal;
                ctx.state.kpi.dropURLLC          = dropURLLC;
                ctx.state.kpi.handoverCount      = ctx.tmp.kpi.handoverCount;
                ctx.state.kpi.rlfCount           = ctx.tmp.kpi.rlfCount;
                ctx.state.kpi.energyJPerCell     = eJPerCell;
                ctx.state.kpi.prbUtilPerCell     = prbUtilPerCell;

                % Derived extras (add these fields into RanStateBus.init for long-term)
                ctx.state.kpi.throughput_bps_total     = thr_bps_total;
                ctx.state.kpi.throughput_Mbps_total    = thr_Mbps_total;
                ctx.state.kpi.energy_J_total           = eJ_total;
                ctx.state.kpi.energy_eff_bit_per_J     = ctx.tmp.kpi.energy_eff_bit_per_J;
                ctx.state.kpi.meanSINR_dB              = ctx.tmp.kpi.meanSINR_dB;
                ctx.state.kpi.meanMCS                  = ctx.tmp.kpi.meanMCS;
                ctx.state.kpi.meanBLER                 = ctx.tmp.kpi.meanBLER;
                ctx.state.kpi.dropRatio                = ctx.tmp.kpi.dropRatio;
                ctx.state.kpi.jainFairness             = ctx.tmp.kpi.jainFairness;
                ctx.state.kpi.prbUtilMean              = ctx.tmp.kpi.prbUtilMean;
            end
        end
    end
end

%% ===============================
% Local helpers
%% ===============================

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

