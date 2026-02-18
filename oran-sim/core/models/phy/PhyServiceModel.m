classdef PhyServiceModel
%PHYSERVICEMODEL
%
% Responsibilities:
%   - Iterate per cell scheduled UE list
%   - Call NrPhyMacAdapter
%   - Serve traffic queue
%   - Update throughput / PRB usage
%   - Update network KPI accumulators in RanContext

    properties
        phyMac
    end

    methods
        function obj = PhyServiceModel(cfg, scenario)
            obj.phyMac = NrPhyMacAdapter(cfg, scenario);
        end

        function [obj, ctx] = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;
            numUE   = ctx.cfg.scenario.numUE;

            %% ===============================
            % Initialize per-slot tmp fields
            %% ===============================

            ctx.tmp.lastCQIPerUE        = zeros(numUE,1);
            ctx.tmp.lastMCSPerUE        = zeros(numUE,1);
            ctx.tmp.lastBLERPerUE       = zeros(numUE,1);
            ctx.tmp.lastPRBUsedPerCell  = zeros(numCell,1);
            ctx.tmp.lastServedBitsPerUE = zeros(numUE,1);

            %% ===============================
            % --- NEW: slot KPI temp accum ---
            %% ===============================

            slotSinrVec = ctx.sinr_dB;   % 全 UE SINR
            slotMcsVec  = zeros(numUE,1);
            slotBlerVec = zeros(numUE,1);

            %% ===============================
            % Loop over cells
            %% ===============================

            for c = 1:numCell

                if ~isfield(ctx.tmp,'scheduledUE') || ...
                   isempty(ctx.tmp.scheduledUE{c})
                    continue;
                end

                ueList  = ctx.tmp.scheduledUE{c};
                prbList = ctx.tmp.prbAlloc{c};

                for i = 1:numel(ueList)

                    u   = ueList(i);
                    prb = prbList(i);

                    if u <= 0 || prb <= 0
                        continue;
                    end

                    %% Skip if HO interruption or RLF outage
                    if isfield(ctx,'ueBlockedUntilSlot') && ...
                       ctx.slot < ctx.ueBlockedUntilSlot(u)
                        continue;
                    end
                    if isfield(ctx,'ueInOutageUntilSlot') && ...
                       ctx.slot < ctx.ueInOutageUntilSlot(u)
                        continue;
                    end

                    %% PHY scheduling info
                    schedInfo.ueId   = u;
                    schedInfo.numPRB = prb;
                    schedInfo.mcs    = [];

                    radioMeas.sinr_dB = ctx.sinr_dB(u);

                    %% PHY step
                    obj.phyMac = obj.phyMac.step(schedInfo, radioMeas);

                    bits = obj.phyMac.getServedBits(u);

                    %% Feedback
                    mcsVal  = obj.phyMac.lastMCS(u);
                    blerVal = obj.phyMac.lastBLER(u);

                    ctx.tmp.lastBLERPerUE(u) = blerVal;
                    ctx.tmp.lastMCSPerUE(u)  = mcsVal;
                    ctx.tmp.lastCQIPerUE(u)  = localSinrToCQI(ctx.sinr_dB(u));

                    slotMcsVec(u)  = mcsVal;
                    slotBlerVec(u) = blerVal;

                    %% Serve traffic queue
                    [ctx.scenario.traffic.model, served] = ...
                        ctx.scenario.traffic.model.serve(u, bits);

                    %% Accumulate throughput
                    ctx.accThroughputBitPerUE(u) = ...
                        ctx.accThroughputBitPerUE(u) + served;

                    ctx.tmp.lastServedBitsPerUE(u) = ...
                        ctx.tmp.lastServedBitsPerUE(u) + served;

                    %% PRB usage accounting
                    if served > 0
                        ctx.accPRBUsedPerCell(c) = ...
                            ctx.accPRBUsedPerCell(c) + prb;

                        ctx.tmp.lastPRBUsedPerCell(c) = ...
                            ctx.tmp.lastPRBUsedPerCell(c) + prb;
                    end
                end
            end

            %% ===============================
            % --- NEW: Accumulate KPI to Context ---
            %% ===============================

            % SINR (all UE)
            ctx = ctx.accSinr(slotSinrVec);

            % MCS (only scheduled UE have nonzero)
            validMcs = slotMcsVec(slotMcsVec > 0);
            if ~isempty(validMcs)
                ctx = ctx.accMcs(validMcs);
            end

            % BLER (scheduled UE)
            validBler = slotBlerVec(slotMcsVec > 0);
            if ~isempty(validBler)
                ctx = ctx.accBler(validBler);
            end

            % PRB used per slot
            ctx = ctx.accPrbUsedSlot(ctx.tmp.lastPRBUsedPerCell);

        end
    end
end


%% ==========================================
% Local helper
%% ==========================================

function cqi = localSinrToCQI(sinr_dB)
    th = [-6 -4 -2 0 2 4 6 8 10 12 14 16 18 20 22];
    cqi = find(sinr_dB < th,1)-1;
    if isempty(cqi), cqi = 15; end
    cqi = max(min(cqi,15),1);
end
