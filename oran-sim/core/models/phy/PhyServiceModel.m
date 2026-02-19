classdef PhyServiceModel
%PHYSERVICEMODEL v4 (slot-level link abstraction + unified debug)
%
% Reads:
%   ctx.sinr_dB
%   ctx.tmp.scheduledUE{c}
%   ctx.tmp.prbAlloc{c}
%   ctx.numPRBPerCell
%   ctx.ueBlockedUntilSlot
%   ctx.ueInOutageUntilSlot
%   ctx.uePostHoUntilSlot
%   ctx.uePostHoSinrPenalty_dB
%   ctx.slot
%
% Writes:
%   ctx.tmp.lastServedBitsPerUE
%   ctx.tmp.lastMCSPerUE
%   ctx.tmp.lastBLERPerUE
%   ctx.tmp.lastCQIPerUE
%   ctx.accThroughputBitPerUE
%
% Debug:
%   ctx.tmp.debug.phy

    properties
        spectralEffTable
        sinrThresholdTable
        blerSlope
        maxMCS
        debugFirstSlots
    end

    methods
        function obj = PhyServiceModel(~,~)

            % Simplified MCS table (index 0..15)
            obj.maxMCS = 15;

            obj.spectralEffTable = [ ...
                0.15 0.23 0.38 0.60 0.88 1.18 1.48 1.91 ...
                2.41 2.73 3.32 3.90 4.52 5.12 5.55 6.23 ];

            obj.sinrThresholdTable = [ ...
                -6 -4 -2 0 2 4 6 8 ...
                10 12 14 16 18 20 22 24 ];

            obj.blerSlope = 1.0;
            obj.debugFirstSlots = 3;
        end

        % ============================================================
        function [obj, ctx] = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            servedBitsPerUE = zeros(numUE,1);
            mcsPerUE        = zeros(numUE,1);
            blerPerUE       = zeros(numUE,1);
            cqiPerUE        = zeros(numUE,1);

            % Prepare debug container
            if ~isfield(ctx.tmp,'debug') || isempty(ctx.tmp.debug)
                ctx.tmp.debug = struct();
            end
            ctx.tmp.debug.phy = struct();
            ctx.tmp.debug.phy.sinrEff = zeros(numUE,1);

            % =========================================================
            % Loop per cell
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

                    % -------------------------------------------------
                    % Outage check (RLF)
                    % -------------------------------------------------
                    if ctx.slot < ctx.ueInOutageUntilSlot(u)
                        continue;
                    end

                    % -------------------------------------------------
                    % HO interruption check
                    % -------------------------------------------------
                    if ctx.slot < ctx.ueBlockedUntilSlot(u)
                        continue;
                    end

                    % -------------------------------------------------
                    % Effective SINR (with post-HO penalty)
                    % -------------------------------------------------
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

                    % CQI mirror MCS (simple mapping)
                    cqiPerUE(u) = mcs;

                    % -------------------------------------------------
                    % BLER model (logistic approx)
                    % -------------------------------------------------
                    thr = obj.sinrThresholdTable(mcs+1);
                    bler = 1 ./ (1 + exp(obj.blerSlope*(sinrEff - thr)));
                    bler = min(max(bler,0),1);

                    blerPerUE(u) = bler;

                    % -------------------------------------------------
                    % Throughput bits
                    % -------------------------------------------------
                    se = obj.spectralEffTable(mcs+1);

                    bits = prb * 12 * 14 * se;  % 12 subcarrier, 14 OFDM symbol
                    bits = bits * (1 - bler);

                    bits = max(bits,0);

                    % -------------------------------------------------
                    % Serve traffic
                    % -------------------------------------------------
                    [ctx.scenario.traffic.model, served] = ...
                        ctx.scenario.traffic.model.serve(u, bits);

                    servedBitsPerUE(u) = served;
                end
            end

            % =========================================================
            % Update accumulators
            % =========================================================
            ctx.accThroughputBitPerUE = ...
                ctx.accThroughputBitPerUE + servedBitsPerUE;

            % =========================================================
            % Write tmp outputs
            % =========================================================
            ctx.tmp.lastServedBitsPerUE = servedBitsPerUE;
            ctx.tmp.lastMCSPerUE        = mcsPerUE;
            ctx.tmp.lastBLERPerUE       = blerPerUE;
            ctx.tmp.lastCQIPerUE        = cqiPerUE;

            % =========================================================
            % Debug print
            % =========================================================
            if ctx.slot <= obj.debugFirstSlots
                %disp("PHY debug SINR eff:");
                %disp(ctx.tmp.debug.phy.sinrEff(:).');
                %disp("PHY served bits per UE:");
                %disp(servedBitsPerUE(:).');
            end
        end
    end

    % ================================================================
    % Private
    % ================================================================
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
    end
end
