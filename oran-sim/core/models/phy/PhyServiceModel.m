classdef PhyServiceModel
%PHYSERVICEMODEL
%
% Responsibilities:
%   - Iterate per cell scheduled UE list
%   - Call NrPhyMacAdapter
%   - Serve traffic queue
%   - Update throughput / PRB usage
%   - Provide per-slot served bits for PF scheduler
%
% Inputs (from ctx.tmp):
%   scheduledUE{c}
%   prbAlloc{c}
%
% Outputs (to ctx.tmp):
%   lastCQIPerUE
%   lastMCSPerUE
%   lastBLERPerUE
%   lastPRBUsedPerCell
%   lastServedBitsPerUE

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

            if ~isfield(ctx.tmp,'lastCQIPerUE')
                ctx.tmp.lastCQIPerUE = zeros(numUE,1);
            end
            if ~isfield(ctx.tmp,'lastMCSPerUE')
                ctx.tmp.lastMCSPerUE = zeros(numUE,1);
            end
            if ~isfield(ctx.tmp,'lastBLERPerUE')
                ctx.tmp.lastBLERPerUE = zeros(numUE,1);
            end
            if ~isfield(ctx.tmp,'lastPRBUsedPerCell')
                ctx.tmp.lastPRBUsedPerCell = zeros(numCell,1);
            end
            if ~isfield(ctx.tmp,'lastServedBitsPerUE')
                ctx.tmp.lastServedBitsPerUE = zeros(numUE,1);
            end

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

                    %% PHY step (HARQ handled internally)
                    obj.phyMac = obj.phyMac.step(schedInfo, radioMeas);

                    bits = obj.phyMac.getServedBits(u);
                    
                    %---------------print--------------------------------------
                    %if ctx.slot <= 5
                    %    fprintf("Slot %d UE %d SINR %.2f MCS %d Bits %.0f\n", ...
                    %        ctx.slot, u, ctx.sinr_dB(u), ...
                    %        obj.phyMac.lastMCS(u), bits);
                    %end


                    %% Feedback
                    ctx.tmp.lastBLERPerUE(u) = obj.phyMac.lastBLER(u);
                    ctx.tmp.lastMCSPerUE(u)  = obj.phyMac.lastMCS(u);

                    % CQI approximate (for state bus visibility)
                    ctx.tmp.lastCQIPerUE(u)  = localSinrToCQI(ctx.sinr_dB(u));

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

