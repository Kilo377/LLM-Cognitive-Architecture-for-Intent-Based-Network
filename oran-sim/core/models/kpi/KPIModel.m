classdef KPIModel
% KPIMODEL v5.0 (Competition-aware version)
%
% 新增：
%   - SINR分布统计
%   - 干扰压力指数
%   - 容量饱和指数
%   - 小区负载不均衡
%   - 系统拥塞指数
%
% 仍然：
%   - 只写 ctx.tmp.kpi
%   - Episode来自 ctx.acc*
%   - Slot来自 ctx.tmp*

    properties
        avgPacketBitsForDropRatio = 12000
        debugFirstSlots = 3
    end

    methods

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            if ~isfield(ctx.tmp,'kpi') || isempty(ctx.tmp.kpi)
                ctx.tmp.kpi = struct();
            end

            %% ===============================================
            % 1) Time base
            %% ===============================================
            t_s = max(double(ctx.slot) * double(ctx.dt), eps);

            %% ===============================================
            % 2) Throughput
            %% ===============================================
            thrBitPerUE = ctx.accThroughputBitPerUE(:);
            thrBitTotal = sum(thrBitPerUE);

            thr_bps_total  = thrBitTotal / t_s;
            thr_Mbps_total = thr_bps_total / 1e6;

            ctx.tmp.kpi.throughput_Mbps_total = thr_Mbps_total;
            ctx.tmp.kpi.jainFairness = localJain(thrBitPerUE);

            %% ===============================================
            % 3) Energy
            %% ===============================================
            eJPerCell = ctx.accEnergyJPerCell(:);
            eJ_total  = sum(eJPerCell);

            ctx.tmp.kpi.energy_J_total = eJ_total;

            if eJ_total > 0
                ctx.tmp.kpi.energy_eff_bit_per_J = thrBitTotal / eJ_total;
            else
                ctx.tmp.kpi.energy_eff_bit_per_J = 0;
            end

            %% ===============================================
            % 4) PRB Utilization
            %% ===============================================
            prbUsed  = ctx.accPRBUsedPerCell(:);
            prbTotal = ctx.accPRBTotalPerCell(:);

            prbTotalSafe = max(prbTotal,1);
            prbUtil = min(max(prbUsed ./ prbTotalSafe,0),1);

            ctx.tmp.kpi.prbUtilPerCell = prbUtil;
            ctx.tmp.kpi.prbUtilMean    = mean(prbUtil);

            % 小区不均衡
            ctx.tmp.kpi.prbImbalance = std(prbUtil);

            %% ===============================================
            % 5) SINR 分布统计
            %% ===============================================
            if numel(ctx.sinr_dB) == numUE

                sinr = ctx.sinr_dB(:);

                ctx.tmp.kpi.meanSINR_dB = mean(sinr);
                ctx.tmp.kpi.p10SINR_dB  = prctile(sinr,10);
                ctx.tmp.kpi.p50SINR_dB  = prctile(sinr,50);
                ctx.tmp.kpi.p90SINR_dB  = prctile(sinr,90);

                % SINR离散度
                ctx.tmp.kpi.sinrStd = std(sinr);

            else
                ctx.tmp.kpi.meanSINR_dB = 0;
                ctx.tmp.kpi.p10SINR_dB  = 0;
                ctx.tmp.kpi.p50SINR_dB  = 0;
                ctx.tmp.kpi.p90SINR_dB  = 0;
                ctx.tmp.kpi.sinrStd     = 0;
            end

            %% ===============================================
            % 6) BLER / PHY质量
            %% ===============================================
            if isfield(ctx.tmp,'lastBLERPerUE')
                ctx.tmp.kpi.meanBLER = mean(ctx.tmp.lastBLERPerUE(:));
            else
                ctx.tmp.kpi.meanBLER = 0;
            end

            %% ===============================================
            % 7) Drop统计
            %% ===============================================
            dropTotal = double(ctx.accDroppedTotal);

            deliveredPktsApprox = thrBitTotal / max(obj.avgPacketBitsForDropRatio,1);
            denom = dropTotal + deliveredPktsApprox;

            if denom > 0
                dropRatio = dropTotal / denom;
            else
                dropRatio = 0;
            end

            ctx.tmp.kpi.dropRatio = dropRatio;

            %% ===============================================
            % 8) Mobility
            %% ===============================================
            ctx.tmp.kpi.handoverCount = ctx.accHOCount;
            ctx.tmp.kpi.rlfCount      = ctx.accRLFCount;

            %% ===============================================
            % 9) 新增：干扰压力指数
            %% ===============================================
            if isfield(ctx.tmp,'channel') && ...
               isfield(ctx.tmp.channel,'interference_dBm')

                interf = ctx.tmp.channel.interference_dBm;
                interf = interf(isfinite(interf));

                if ~isempty(interf)
                    ctx.tmp.kpi.meanInterference_dBm = mean(interf);
                    ctx.tmp.kpi.interfStd = std(interf);
                else
                    ctx.tmp.kpi.meanInterference_dBm = -inf;
                    ctx.tmp.kpi.interfStd = 0;
                end
            else
                ctx.tmp.kpi.meanInterference_dBm = -inf;
                ctx.tmp.kpi.interfStd = 0;
            end

            %% ===============================================
            % 10) 系统拥塞指数
            %% ===============================================
            % 综合：高负载 + 高BLER + 低p10SINR
            congestion = ...
                0.4 * ctx.tmp.kpi.prbUtilMean + ...
                0.3 * ctx.tmp.kpi.meanBLER + ...
                0.3 * max(0, -ctx.tmp.kpi.p10SINR_dB / 10);

            ctx.tmp.kpi.congestionIndex = congestion;

            %% ===============================================
            % 11) Debug
            %% ===============================================
            if ctx.slot <= obj.debugFirstSlots
                fprintf('[KPI] slot=%d Thr=%.2f Mbps | SINR(p10)=%.2f | Cong=%.2f\n', ...
                    ctx.slot, ...
                    thr_Mbps_total, ...
                    ctx.tmp.kpi.p10SINR_dB, ...
                    congestion);
            end
        end
    end
end


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