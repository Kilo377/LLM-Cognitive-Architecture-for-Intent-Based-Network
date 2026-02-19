classdef SchedulerPRBModel
% SCHEDULERPRBMODEL v5.2 (ctrl-safe + debug)
%
% Reads:
%   ctx.numPRBPerCell / ctx.numPRB
%   ctx.servingCell
%   ctx.rrPtr
%   ctx.ctrl.cellSleepState
%   ctx.ctrl.selectedUE
%   ctx.scenario.traffic.model
%   ctx.ueBlockedUntilSlot
%
% Writes:
%   ctx.tmp.scheduledUE{c}
%   ctx.tmp.prbAlloc{c}
%   ctx.tmp.cell.prbTotal / prbUsed / schedUECount
%   ctx.tmp.lastPRBUsedPerCell
%   ctx.rrPtr

    properties
        prbChunk
        actionBoost
        maxUEPerCell
        debugFirstSlots
    end

    methods
        function obj = SchedulerPRBModel()
            obj.prbChunk        = 10;
            obj.actionBoost     = 0.6;
            obj.maxUEPerCell    = 4;
            obj.debugFirstSlots = 3;
        end

        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;
            numUE   = ctx.cfg.scenario.numUE;

            %--------------------------------------------------
            % Init per-slot containers
            %--------------------------------------------------
            ctx.tmp.scheduledUE = cell(numCell,1);
            ctx.tmp.prbAlloc    = cell(numCell,1);

            if ~isfield(ctx.tmp,'cell') || isempty(ctx.tmp.cell)
                ctx.tmp.cell = struct();
            end

            if ~isfield(ctx.tmp,'debug') || isempty(ctx.tmp.debug)
                ctx.tmp.debug = struct();
            end
            ctx.tmp.debug.scheduler = struct();
            ctx.tmp.debug.scheduler.selU = zeros(numCell,1);
            ctx.tmp.debug.scheduler.selU_reason = strings(numCell,1);

            %--------------------------------------------------
            % Per-cell PRB total
            %--------------------------------------------------
            if isprop(ctx,'numPRBPerCell') && numel(ctx.numPRBPerCell)==numCell
                prbTotalVec = ctx.numPRBPerCell(:);
            else
                prbTotalVec = ctx.numPRB * ones(numCell,1);
            end

            ctx.tmp.cell.prbTotal      = prbTotalVec;
            ctx.tmp.cell.prbUsed       = zeros(numCell,1);
            ctx.tmp.cell.schedUECount  = zeros(numCell,1);

            %--------------------------------------------------
            % Sleep gating (from ctx.ctrl)
            %--------------------------------------------------
            cellIsSleeping = false(numCell,1);
            if isprop(ctx,'ctrl') && ~isempty(ctx.ctrl) && isfield(ctx.ctrl,'cellSleepState')
                ss = ctx.ctrl.cellSleepState(:);
                if numel(ss)==numCell
                    cellIsSleeping = (round(ss) >= 1);
                end
            end

            %--------------------------------------------------
            % Ensure lastPRBUsedPerCell exists (for Energy/Radio)
            %--------------------------------------------------
            if ~isfield(ctx.tmp,'lastPRBUsedPerCell') || isempty(ctx.tmp.lastPRBUsedPerCell)
                ctx.tmp.lastPRBUsedPerCell = zeros(numCell,1);
            end

            %--------------------------------------------------
            % Per-cell scheduling
            %--------------------------------------------------
            for c = 1:numCell

                totalPRB = prbTotalVec(c);

                % episode counter
                ctx.accPRBTotalPerCell(c) = ctx.accPRBTotalPerCell(c) + totalPRB;

                if totalPRB <= 0
                    ctx.tmp.debug.scheduler.selU_reason(c) = "totalPRB<=0";
                    continue;
                end

                if cellIsSleeping(c)
                    ctx.tmp.debug.scheduler.selU_reason(c) = "cellSleeping";
                    continue;
                end

                ueSet = find(ctx.servingCell == c);
                if isempty(ueSet)
                    ctx.tmp.debug.scheduler.selU_reason(c) = "noUEinCell";
                    continue;
                end

                ueSet = obj.filterHoBlockedUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.debug.scheduler.selU_reason(c) = "allHOBlocked";
                    continue;
                end

                ueSet = obj.filterEmptyBufferUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.debug.scheduler.selU_reason(c) = "allEmptyBuffer";
                    continue;
                end

                % Selected UE from ctrl
                [selU, reason] = obj.getSelectedUE_fromCtrl(ctx, c, numUE, ueSet);
                ctx.tmp.debug.scheduler.selU(c) = selU;
                ctx.tmp.debug.scheduler.selU_reason(c) = reason;

                % Allocate PRB
                [ctx, schedUE, prbAlloc] = obj.allocatePRB(ctx, c, ueSet, selU, totalPRB);

                % Aggregate duplicate
                [schedUE, prbAlloc] = obj.aggregateAlloc(schedUE, prbAlloc);

                % Enforce max UE
                [schedUE, prbAlloc] = obj.enforceMaxUE(schedUE, prbAlloc, selU);

                % Finalize
                ctx.tmp.scheduledUE{c} = schedUE(:);
                ctx.tmp.prbAlloc{c}    = prbAlloc(:);

                prbUsed = sum(prbAlloc);
                prbUsed = min(max(prbUsed,0), totalPRB);

                ctx.tmp.cell.prbUsed(c)       = prbUsed;
                ctx.tmp.cell.schedUECount(c)  = numel(schedUE);
                ctx.tmp.lastPRBUsedPerCell(c) = prbUsed;
            end

            %--------------------------------------------------
            % Minimal debug print
            %--------------------------------------------------
            if ctx.slot <= obj.debugFirstSlots
                %disp("Scheduler debug selU per cell:");
                %disp(ctx.tmp.debug.scheduler.selU(:).');
                %disp("Scheduler selU reason per cell:");
                %disp(ctx.tmp.debug.scheduler.selU_reason(:).');
            end
        end
    end

    %==========================================================
    % Private
    %==========================================================
    methods (Access = private)

        function ueSet = filterHoBlockedUE(~, ctx, ueSet)
            ok = true(size(ueSet));
            for i = 1:numel(ueSet)
                u = ueSet(i);
                if isprop(ctx,'ueBlockedUntilSlot') && ctx.slot < ctx.ueBlockedUntilSlot(u)
                    ok(i) = false;
                end
            end
            ueSet = ueSet(ok);
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

        function [selU, reason] = getSelectedUE_fromCtrl(~, ctx, c, numUE, ueSet)
            selU = 0;
            reason = "noCtrl";

            if ~isprop(ctx,'ctrl') || isempty(ctx.ctrl) || ~isfield(ctx.ctrl,'selectedUE')
                return;
            end

            sel = ctx.ctrl.selectedUE;

            if ~isvector(sel) || numel(sel) < c
                reason = "selectedUESizeMismatch";
                return;
            end

            v = round(sel(c));

            if v < 1 || v > numUE
                reason = "selectedUEOutOfRange";
                return;
            end

            if ~any(ueSet == v)
                reason = "selectedUENotInThisCell";
                return;
            end

            selU = v;
            reason = "ok";
        end

        function [ctx, schedUE, prbAlloc] = allocatePRB(obj, ctx, c, ueSet, selU, totalPRB)

            if numel(ueSet) == 1
                schedUE  = ueSet(:);
                prbAlloc = totalPRB;
                return;
            end

            if selU > 0
                prbSel = max(1, floor(totalPRB * obj.actionBoost));
                prbSel = min(prbSel, totalPRB);

                prbRem = totalPRB - prbSel;

                others = ueSet(ueSet ~= selU);

                [ctx, rrList, rrAlloc] = obj.rrAllocate(ctx, c, others, prbRem);

                schedUE  = [selU; rrList(:)];
                prbAlloc = [prbSel; rrAlloc(:)];
            else
                [ctx, schedUE, prbAlloc] = obj.rrAllocate(ctx, c, ueSet, totalPRB);
            end
        end

        function [ctx, ueList, alloc] = rrAllocate(obj, ctx, c, ueSet, prbBudget)

            ueList = [];
            alloc  = [];

            if prbBudget <= 0 || isempty(ueSet)
                return;
            end

            nChunk   = ceil(prbBudget / obj.prbChunk);
            chunkPRB = obj.prbChunk;

            ptr = ctx.rrPtr(c);

            for k = 1:nChunk
                idx = mod(ptr-1, numel(ueSet)) + 1;
                u   = ueSet(idx);
                ptr = ptr + 1;

                prb = min(chunkPRB, prbBudget);
                prbBudget = prbBudget - prb;

                ueList(end+1,1) = u;   %#ok<AGROW>
                alloc(end+1,1)  = prb; %#ok<AGROW>

                if prbBudget <= 0
                    break;
                end
            end

            ctx.rrPtr(c) = ptr;
        end

        function [ueList2, alloc2] = aggregateAlloc(~, ueList, alloc)

            if isempty(ueList)
                ueList2 = ueList;
                alloc2  = alloc;
                return;
            end

            ueList2 = [];
            alloc2  = [];

            for i = 1:numel(ueList)
                u = ueList(i);
                p = alloc(i);

                j = find(ueList2 == u, 1);

                if isempty(j)
                    ueList2(end+1,1) = u; %#ok<AGROW>
                    alloc2(end+1,1)  = p; %#ok<AGROW>
                else
                    alloc2(j) = alloc2(j) + p;
                end
            end
        end

        function [ueList, alloc] = enforceMaxUE(obj, ueList, alloc, selU)

            if isempty(ueList)
                return;
            end

            K = obj.maxUEPerCell;

            if K <= 0
                ueList = [];
                alloc  = [];
                return;
            end

            if numel(ueList) <= K
                return;
            end

            if selU > 0
                idxSel = find(ueList == selU, 1);
                if ~isempty(idxSel)
                    ueList = [ueList(idxSel); ueList([1:idxSel-1, idxSel+1:end])];
                    alloc  = [alloc(idxSel);  alloc([1:idxSel-1, idxSel+1:end])];
                end
            end

            ueList = ueList(1:K);
            alloc  = alloc(1:K);
        end
    end
end

