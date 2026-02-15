classdef KPIModel
%KPIMODEL Compute derived KPI values (no state bus write)

    methods

        function obj = KPIModel()
        end

        function ctx = step(~, ctx)

            totalBits = sum(ctx.accThroughputBitPerUE);
            totalTime = ctx.slot * ctx.dt;

            if totalTime > 0
                ctx.tmp.throughput_bps_total = totalBits / totalTime;
            else
                ctx.tmp.throughput_bps_total = 0;
            end

            ctx.tmp.energyJ_total = sum(ctx.accEnergyJPerCell);

            if ctx.tmp.energyJ_total > 0
                ctx.tmp.energy_eff_bit_per_J = ...
                    totalBits / ctx.tmp.energyJ_total;
            else
                ctx.tmp.energy_eff_bit_per_J = 0;
            end

            prbTotal = max(ctx.accPRBTotalPerCell,1);
            ctx.tmp.prbUtilPerCell = ...
                ctx.accPRBUsedPerCell ./ prbTotal;

        end
    end
end

