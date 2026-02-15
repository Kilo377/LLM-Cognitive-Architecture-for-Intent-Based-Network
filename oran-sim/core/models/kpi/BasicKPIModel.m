classdef BasicKPIModel < KPIModel

    methods
        function ctx = step(~, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            if ~isfield(ctx.tmp,'derivedKPI')
                ctx.tmp.derivedKPI = struct();
            end

            %% =====================================================
            % 1️⃣ Energy Efficiency
            %% =====================================================
            totalThroughput = sum(ctx.accThroughputBitPerUE);
            totalEnergy     = sum(ctx.accEnergyJPerCell);

            if totalEnergy > 0
                ctx.tmp.derivedKPI.energyEfficiency = ...
                    totalThroughput / totalEnergy;
            else
                ctx.tmp.derivedKPI.energyEfficiency = 0;
            end

            %% =====================================================
            % 2️⃣ Jain Fairness Index
            %% =====================================================
            x = ctx.accThroughputBitPerUE;

            if sum(x.^2) > 0
                ctx.tmp.derivedKPI.jainFairness = ...
                    (sum(x)^2) / (numUE * sum(x.^2));
            else
                ctx.tmp.derivedKPI.jainFairness = 0;
            end

            %% =====================================================
            % 3️⃣ HO Rate
            %% =====================================================
            if ctx.slot > 0
                ctx.tmp.derivedKPI.hoRate = ...
                    ctx.accHOCount / ctx.slot;
            else
                ctx.tmp.derivedKPI.hoRate = 0;
            end

            %% =====================================================
            % 4️⃣ URLLC Violation Ratio
            %% =====================================================
            totalDrops = ctx.accDroppedURLLC;
            totalTraffic = ctx.accDroppedURLLC + ...
                sum(ctx.accThroughputBitPerUE > 0); % 简化近似

            if totalTraffic > 0
                ctx.tmp.derivedKPI.urllcViolationRatio = ...
                    totalDrops / totalTraffic;
            else
                ctx.tmp.derivedKPI.urllcViolationRatio = 0;
            end

            %% =====================================================
            % 5️⃣ Instant PRB Utilization
            %% =====================================================
            if isfield(ctx.tmp,'lastPRBUsedPerCell')
                util = ctx.tmp.lastPRBUsedPerCell ./ ...
                       max(ctx.numPRB,1);
            else
                util = zeros(numCell,1);
            end

            ctx.tmp.derivedKPI.instantPRBUtil = util;

            %% =====================================================
            % 6️⃣ Cell Load Imbalance Index
            %% =====================================================
            if numCell > 1
                mu = mean(util);
                sigma = std(util);

                if mu > 0
                    ctx.tmp.derivedKPI.loadImbalance = sigma / mu;
                else
                    ctx.tmp.derivedKPI.loadImbalance = 0;
                end
            else
                ctx.tmp.derivedKPI.loadImbalance = 0;
            end

        end
    end
end
