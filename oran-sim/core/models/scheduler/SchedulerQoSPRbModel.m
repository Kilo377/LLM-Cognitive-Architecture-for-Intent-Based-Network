classdef SchedulerQoSPRbModel
%SCHEDULERQOSPRBMODEL Multi-UE PRB scheduler with QoS + PF
%
% Output (per slot):
%   ctx.tmp.scheduledUE{c} : [Kx1] UE list (can repeat)
%   ctx.tmp.prbAlloc{c}    : [Kx1] PRB per entry
%
% Policy:
%   1) URLLC urgency first (min deadline, urgent count)
%   2) then PF for eMBB-like flows (buffer/avgTput)
%   3) mMTC last
%
% Action hook:
%   ctx.action.scheduling.selectedUE(c) can boost that UE with share actionBoost

    properties
        prbChunk
        actionBoost

        % PF parameters
        pfAlpha              % average throughput smoothing
        pfEps                % prevent div0
        wUrllc
        wEmbb
        wMmtc

        % URLLC urgency threshold
        urgentDeadline_slot
    end

    properties (Access = private)
        avgTputBitPerUE      % moving average throughput for PF [numUE x 1]
        initialized = false
    end

    methods
        function obj = SchedulerQoSPRbModel()
            obj.prbChunk = 10;
            obj.actionBoost = 0.5;

            obj.pfAlpha = 0.95;
            obj.pfEps   = 1e-6;

            obj.wUrllc = 3.0;
            obj.wEmbb  = 1.0;
            obj.wMmtc  = 0.5;

            obj.urgentDeadline_slot = 5;
        end

        function obj = init(obj, ctx)
            numUE = ctx.cfg.scenario.numUE;
            obj.avgTputBitPerUE = ones(numUE,1) * 1e4; % small nonzero start
            obj.initialized = true;
        end

        function [obj, ctx] = step(obj, ctx)

            if ~obj.initialized
                obj = obj.init(ctx);
            end

            numCell = ctx.cfg.scenario.numCell;
            numUE   = ctx.cfg.scenario.numUE;

            if ~isfield(ctx.tmp,'scheduledUE')
                ctx.tmp.scheduledUE = cell(numCell,1);
            end
            if ~isfield(ctx.tmp,'prbAlloc')
                ctx.tmp.prbAlloc = cell(numCell,1);
            end

            % Update PF averages from last slot served bits if available
            if isfield(ctx.tmp,'lastServedBitsPerUE')
                inst = ctx.tmp.lastServedBitsPerUE(:);
                if numel(inst) == numUE
                    obj.avgTputBitPerUE = obj.pfAlpha * obj.avgTputBitPerUE + (1-obj.pfAlpha) * inst;
                end
            end

            for c = 1:numCell

                % PRB total accounting
                ctx.accPRBTotalPerCell(c) = ctx.accPRBTotalPerCell(c) + ctx.numPRB;

                ueSet = find(ctx.servingCell == c);
                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    continue;
                end

                % Remove outage/HO-blocked UE
                ueSet = obj.filterBlockedUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    continue;
                end

                % Remove empty buffer UE (optional, recommended)
                ueSet = obj.filterEmptyBufferUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    continue;
                end

                % Action selected UE
                selU = obj.getSelectedUE(ctx, c, ueSet, numUE);

                % Decide PRB allocation
                [ueList, prbList] = obj.allocateCell(ctx, c, ueSet, selU);

                ctx.tmp.scheduledUE{c} = ueList(:);
                ctx.tmp.prbAlloc{c}    = prbList(:);
            end
        end
    end

    methods (Access = private)

        function ueSet = filterBlockedUE(~, ctx, ueSet)
            keep = true(size(ueSet));
            for i = 1:numel(ueSet)
                u = ueSet(i);
                if isfield(ctx,'ueBlockedUntilSlot') && ctx.slot < ctx.ueBlockedUntilSlot(u)
                    keep(i) = false;
                end
                if isfield(ctx,'ueInOutageUntilSlot') && ctx.slot < ctx.ueInOutageUntilSlot(u)
                    keep(i) = false;
                end
            end
            ueSet = ueSet(keep);
        end

        function ueSet = filterEmptyBufferUE(~, ctx, ueSet)
            keep = false(size(ueSet));
            for i = 1:numel(ueSet)
                u = ueSet(i);
                q = ctx.scenario.traffic.model.getQueue(u);
                keep(i) = ~isempty(q);
            end
            ueSet = ueSet(keep);
        end

        function selU = getSelectedUE(~, ctx, c, ueSet, numUE)
            selU = 0;
            if ~isempty(ctx.action) && isfield(ctx.action,'scheduling') && ...
                    isfield(ctx.action.scheduling,'selectedUE')
                sel = ctx.action.scheduling.selectedUE;
                if isvector(sel) && numel(sel) >= c
                    v = round(sel(c));
                    if v >= 1 && v <= numUE && any(ueSet == v)
                        selU = v;
                    end
                end
            end
        end

        function [ueList, prbList] = allocateCell(obj, ctx, c, ueSet, selU)

            totalPRB = ctx.numPRB;

            % If action selects one UE, reserve a share for it
            prbSel = 0;
            if selU > 0
                prbSel = max(1, floor(totalPRB * obj.actionBoost));
                prbSel = min(prbSel, totalPRB);
            end
            prbRem = totalPRB - prbSel;

            ueList = [];
            prbList = [];

            % Give reserved PRB to selected UE first
            if prbSel > 0
                ueList(end+1,1)  = selU; %#ok<AGROW>
                prbList(end+1,1) = prbSel; %#ok<AGROW>
                ueSet = ueSet(ueSet ~= selU);
            end

            if prbRem <= 0 || isempty(ueSet)
                return;
            end

            % Fill remaining PRB chunk by chunk using QoS scoring
            nChunk = ceil(prbRem / obj.prbChunk);
            prbBudget = prbRem;

            for k = 1:nChunk
                if prbBudget <= 0 || isempty(ueSet)
                    break;
                end

                % pick UE by QoS score
                u = obj.pickUE(ctx, ueSet);

                prb = min(obj.prbChunk, prbBudget);
                prbBudget = prbBudget - prb;

                ueList(end+1,1)  = u; %#ok<AGROW>
                prbList(end+1,1) = prb; %#ok<AGROW>

                % remove UE if its buffer is now small? (optional)
                % keep it for now; PHY/Traffic will drain.
            end

            % Round-robin tie-breaker can be added later if needed
            % ctx.rrPtr not required here
        end

        function u = pickUE(obj, ctx, ueSet)

            score = -inf(size(ueSet));

            for i = 1:numel(ueSet)
                uu = ueSet(i);

                q = ctx.scenario.traffic.model.getQueue(uu);
                if isempty(q)
                    continue;
                end

                % Summaries
                [bufBits, urgentCnt, minDL, hasURLLC, hasMMTC] = obj.summarizeQueue(q);

                % QoS weights
                w = obj.wEmbb;

                if hasURLLC && minDL <= obj.urgentDeadline_slot
                    w = obj.wUrllc;
                elseif hasMMTC && ~hasURLLC
                    w = obj.wMmtc;
                end

                % PF term: demand / avgThroughput
                pf = bufBits / max(obj.avgTputBitPerUE(uu), obj.pfEps);

                % urgency bump
                urgBump = 1 + 0.3*urgentCnt;

                score(i) = w * pf * urgBump;
            end

            [~, idx] = max(score);
            u = ueSet(idx);
        end

        function [bufBits, urgentCnt, minDL, hasURLLC, hasMMTC] = summarizeQueue(~, q)
            sizes = [q.size];
            bufBits = sum(sizes);

            dl = [q.deadline];
            hasURLLC = any(strcmp({q.type}, 'URLLC'));
            hasMMTC  = any(strcmp({q.type}, 'mMTC'));

            urgentCnt = sum(isfinite(dl) & dl <= 5);

            if any(isfinite(dl))
                minDL = min(dl(isfinite(dl)));
            else
                minDL = inf;
            end
        end
    end
end
