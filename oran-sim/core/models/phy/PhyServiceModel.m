classdef PhyServiceModel
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

            % Ensure tmp fields exist (normally created by ctx.clearSlotTemp)
            if ~isfield(ctx.tmp,'lastCQIPerUE'),  ctx.tmp.lastCQIPerUE  = zeros(numUE,1); end
            if ~isfield(ctx.tmp,'lastMCSPerUE'),  ctx.tmp.lastMCSPerUE  = zeros(numUE,1); end
            if ~isfield(ctx.tmp,'lastBLERPerUE'), ctx.tmp.lastBLERPerUE = zeros(numUE,1); end
            if ~isfield(ctx.tmp,'lastPRBUsedPerCell'), ctx.tmp.lastPRBUsedPerCell = zeros(numCell,1); end

            % Scheduler outputs must exist
            if ~isfield(ctx.tmp,'scheduledUE') || ~isfield(ctx.tmp,'prbAlloc')
                return;
            end

            for c = 1:numCell

                ueList = ctx.tmp.scheduledUE{c};
                if isempty(ueList)
                    continue;
                end

                prbList = ctx.tmp.prbAlloc{c};
                if isempty(prbList)
                    continue;
                end

                % Make lengths consistent
                n = min(numel(ueList), numel(prbList));
                ueList  = ueList(1:n);
                prbList = prbList(1:n);

                for i = 1:n
                    u   = ueList(i);
                    prb = prbList(i);

                    if u <= 0 || u > numUE || prb <= 0
                        continue;
                    end

                    % PRB accounting: allocated PRB is consumed regardless of success
                    ctx.accPRBUsedPerCell(c) = ctx.accPRBUsedPerCell(c) + prb;
                    ctx.tmp.lastPRBUsedPerCell(c) = ctx.tmp.lastPRBUsedPerCell(c) + prb;

                    % HO interruption: no data served during interruption
                    if ctx.slot < ctx.ueBlockedUntilSlot(u)
                        continue;
                    end

                    schedInfo.ueId   = u;
                    schedInfo.numPRB = prb;
                    schedInfo.mcs    = [];

                    radioMeas.sinr_dB = ctx.sinr_dB(u);

                    obj.phyMac = obj.phyMac.step(schedInfo, radioMeas);
                    bits = obj.phyMac.getServedBits(u);

                    % PHY feedback (last write wins in this slot)
                    ctx.tmp.lastBLERPerUE(u) = obj.phyMac.lastBLER(u);
                    ctx.tmp.lastCQIPerUE(u)  = localSinrToCQI(ctx.sinr_dB(u));
                    ctx.tmp.lastMCSPerUE(u)  = max(ctx.tmp.lastCQIPerUE(u)-1,0);

                    % Serve traffic
                    [ctx.scenario.traffic.model, served] = ...
                        ctx.scenario.traffic.model.serve(u, bits);

                    ctx.accThroughputBitPerUE(u) = ...
                        ctx.accThroughputBitPerUE(u) + served;
                end
            end
        end
    end
end

function cqi = localSinrToCQI(sinr_dB)
th = [-5 -2 1 3 5 7 9 11 13 15 17 19 21 23 25];
cqi = find(sinr_dB < th,1)-1;
if isempty(cqi), cqi = 15; end
cqi = max(min(cqi,15),1);
end
