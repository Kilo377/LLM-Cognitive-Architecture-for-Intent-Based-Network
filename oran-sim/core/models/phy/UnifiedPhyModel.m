classdef UnifiedPhyModel
% UNIFIEDPHYMODEL v1.0 (Light-Random NR Abstraction)
%
% 统一 PhyServiceModel + NrPhyMacAdapter
% 
% 特点：
%   - SINR -> MCS
%   - MCS -> TBS
%   - Logistic BLER
%   - 轻微随机扰动
%   - 无HARQ状态机
%   - 与KPI完全兼容
%

    properties
        maxMCS = 27

        % NR-like mapping
        sinrThresholdTable
        randomStdFactor = 0.05   % 轻微随机幅度

        debugFirstSlots = 3
    end

    methods

        function obj = UnifiedPhyModel(~,~)

            obj.sinrThresholdTable = -7 + 0.9*(0:27);
        end

        % ============================================================
        function [obj, ctx] = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            servedBitsPerUE = zeros(numUE,1);
            mcsPerUE        = zeros(numUE,1);
            blerPerUE       = zeros(numUE,1);

            if ~isfield(ctx.tmp,'debug')
                ctx.tmp.debug = struct();
            end
            ctx.tmp.debug.phy = struct();
            ctx.tmp.debug.phy.sinrEff = zeros(numUE,1);

            % =========================================================
            % per cell scheduling
            % =========================================================
            for c = 1:numCell

                if isempty(ctx.tmp.scheduledUE{c})
                    continue;
                end

                ueList  = ctx.tmp.scheduledUE{c};
                prbList = ctx.tmp.prbAlloc{c};

                for k = 1:numel(ueList)

                    u   = ueList(k);
                    prb = prbList(k);

                    if ctx.slot < ctx.ueInOutageUntilSlot(u)
                        continue;
                    end

                    if ctx.slot < ctx.ueBlockedUntilSlot(u)
                        continue;
                    end

                    % Effective SINR
                    sinrEff = ctx.sinr_dB(u);

                    if ctx.slot < ctx.uePostHoUntilSlot(u)
                        sinrEff = sinrEff - ctx.uePostHoSinrPenalty_dB(u);
                    end

                    ctx.tmp.debug.phy.sinrEff(u) = sinrEff;

                    % -------------------------------------------------
                    % MCS selection
                    % -------------------------------------------------
                    mcs = obj.selectMCS(sinrEff);
                    mcsPerUE(u) = mcs;

                    % -------------------------------------------------
                    % TBS
                    % -------------------------------------------------
                    tbs_bits = obj.computeTBS(mcs, prb);

                    % -------------------------------------------------
                    % BLER (logistic)
                    % -------------------------------------------------
                    thr = obj.sinrThresholdTable(mcs+1);
                    kSlope = min(1.6, 0.9 + 0.02*mcs);

                    bler = 1 / (1 + exp(kSlope*(sinrEff - thr)));

                    % 轻微随机扰动
                    bler = bler + obj.randomStdFactor * randn;
                    bler = min(max(bler,0),1);

                    blerPerUE(u) = bler;

                    % -------------------------------------------------
                    % Served bits (期望 + 小随机)
                    % -------------------------------------------------
                    served = tbs_bits * (1 - bler);

                    % 小比例波动
                    served = served * (1 + obj.randomStdFactor * randn);

                    served = max(served,0);

                    [ctx.scenario.traffic.model, servedFinal] = ...
                        ctx.scenario.traffic.model.serve(u, served);

                    servedBitsPerUE(u) = servedFinal;
                end
            end

            % =========================================================
            % Accumulate
            % =========================================================
            ctx.accThroughputBitPerUE = ...
                ctx.accThroughputBitPerUE + servedBitsPerUE;

            ctx.tmp.lastServedBitsPerUE = servedBitsPerUE;
            ctx.tmp.lastMCSPerUE        = mcsPerUE;
            ctx.tmp.lastBLERPerUE       = blerPerUE;

            if ctx.slot <= obj.debugFirstSlots
                fprintf('[PHY] slot=%d meanBLER=%.3f\n', ...
                    ctx.slot, mean(blerPerUE));
            end
        end
    end

    methods (Access = private)

        function mcs = selectMCS(obj, sinr)

            mcs = 0;

            for i = obj.maxMCS:-1:0
                if sinr >= obj.sinrThresholdTable(i+1)
                    mcs = i;
                    return;
                end
            end
        end

        function tbs_bits = computeTBS(~, mcs, numPRB)

            [Qm, R] = localMcsToModCod(mcs);

            Nre = 12 * 14;
            overhead = 0.25;
            NreEff = floor(Nre * (1-overhead));

            tbs_bits = floor(numPRB * NreEff * Qm * R);
            tbs_bits = max(tbs_bits,0);
        end
    end
end


function [Qm, R] = localMcsToModCod(mcs)

if mcs <= 4
    Qm = 2;  R = 0.12 + 0.08*mcs;
elseif mcs <= 10
    Qm = 2;  R = 0.45 + 0.03*(mcs-5);
elseif mcs <= 17
    Qm = 4;  R = 0.35 + 0.04*(mcs-11);
elseif mcs <= 23
    Qm = 6;  R = 0.35 + 0.04*(mcs-18);
else
    Qm = 8;  R = 0.45 + 0.03*(mcs-24);
end

R = min(max(R,0.05),0.95);
end