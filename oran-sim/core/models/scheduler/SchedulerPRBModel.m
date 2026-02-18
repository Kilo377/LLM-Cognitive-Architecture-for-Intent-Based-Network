classdef SchedulerPRBModel
    properties
        prbChunk        % PRB granularity
        actionBoost     % PRB share for selected UE
        maxUEPerCell    % max concurrent scheduled UE per cell per slot
    end

    methods
        function obj = SchedulerPRBModel()
            obj.prbChunk     = 10;
            obj.actionBoost  = 0.6;
            obj.maxUEPerCell = 4;   % contention knob
        end

        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;
            numUE   = ctx.cfg.scenario.numUE;

            % Always init per-slot tmp containers
            ctx.tmp.scheduledUE = cell(numCell,1);
            ctx.tmp.prbAlloc    = cell(numCell,1);

            % --- NEW: export per-slot cell-level scheduler observability ---
            if ~isfield(ctx.tmp,'cell'), ctx.tmp.cell = struct(); end
            ctx.tmp.cell.prbTotal = ctx.numPRB * ones(numCell,1);
            ctx.tmp.cell.prbUsed  = zeros(numCell,1);
            ctx.tmp.cell.schedUECount = zeros(numCell,1);

            % Optional: sleep gating (ActionApplier may set this)
            cellIsSleeping = false(numCell,1);
            if isfield(ctx.tmp,'cellIsSleeping') && isnumeric(ctx.tmp.cellIsSleeping)
                cellIsSleeping = logical(ctx.tmp.cellIsSleeping(:));
                if numel(cellIsSleeping) ~= numCell
                    cellIsSleeping = false(numCell,1);
                end
            end

            for c = 1:numCell

                % If sleeping, schedule nothing but still account PRB total for fairness
                ctx.accPRBTotalPerCell(c) = ctx.accPRBTotalPerCell(c) + ctx.numPRB;

                if cellIsSleeping(c)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    ctx.tmp.cell.prbUsed(c) = 0;
                    ctx.tmp.cell.schedUECount(c) = 0;
                    continue;
                end

                ueSet = find(ctx.servingCell == c);
                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    ctx.tmp.cell.prbUsed(c) = 0;
                    ctx.tmp.cell.schedUECount(c) = 0;
                    continue;
                end

                % Filter HO-blocked UE
                ueSet = obj.filterHoBlockedUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    ctx.tmp.cell.prbUsed(c) = 0;
                    ctx.tmp.cell.schedUECount(c) = 0;
                    continue;
                end

                % Filter empty buffer UE
                ueSet = obj.filterEmptyBufferUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    ctx.tmp.cell.prbUsed(c) = 0;
                    ctx.tmp.cell.schedUECount(c) = 0;
                    continue;
                end

                % Action selected UE
                selU = obj.getSelectedUE(ctx, c, numUE, ueSet);

                % Allocate PRB (RR + optional boost), update rrPtr
                [ctx, schedUE, prbAlloc] = obj.allocatePRB(ctx, c, ueSet, selU);

                % Aggregate duplicate UE entries
                [schedUE, prbAlloc] = obj.aggregateAlloc(schedUE, prbAlloc);

                % Enforce max concurrent UE per cell
                [schedUE, prbAlloc] = obj.enforceMaxUE(schedUE, prbAlloc, selU);

                % Finalize
                ctx.tmp.scheduledUE{c} = schedUE(:);
                ctx.tmp.prbAlloc{c}    = prbAlloc(:);

                % --- NEW: per-slot cell metrics for state bus ---
                prbUsed = sum(prbAlloc);
                prbUsed = min(max(prbUsed,0), ctx.numPRB);

                ctx.tmp.cell.prbUsed(c) = prbUsed;
                ctx.tmp.cell.schedUECount(c) = numel(schedUE);

                % 让 RanContext.updateStateBus 能看到 PRB 用量
                %（PHY 也会写 lastPRBUsedPerCell，但这里可用于"调度层是否生效"的诊断）
                if ~isfield(ctx.tmp,'lastPRBUsedPerCell')
                    ctx.tmp.lastPRBUsedPerCell = zeros(numCell,1);
                end
                ctx.tmp.lastPRBUsedPerCell(c) = prbUsed;

            end
        end
    end

    methods (Access = private)

        function ueSet = filterHoBlockedUE(~, ctx, ueSet)
            ok = true(size(ueSet));
            for i = 1:numel(ueSet)
                u = ueSet(i);
                if isfield(ctx,'ueBlockedUntilSlot') && ctx.slot < ctx.ueBlockedUntilSlot(u)
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

        function selU = getSelectedUE(~, ctx, c, numUE, ueSet)
            selU = 0;

            if isempty(ctx.action) || ~isfield(ctx.action,'scheduling') || ...
                    ~isfield(ctx.action.scheduling,'selectedUE')
                return;
            end

            sel = ctx.action.scheduling.selectedUE;
            if ~isvector(sel) || numel(sel) < c
                return;
            end

            v = round(sel(c));
            if v >= 1 && v <= numUE && any(ueSet == v)
                selU = v;
            end
        end

        function [ctx, schedUE, prbAlloc] = allocatePRB(obj, ctx, c, ueSet, selU)

            totalPRB = ctx.numPRB;

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

            % Ensure selected UE kept if present
            if selU > 0
                idxSel = find(ueList == selU, 1);
                if ~isempty(idxSel)
                    ueList = [ueList(idxSel); ueList([1:idxSel-1, idxSel+1:end])];
                    alloc  = [alloc(idxSel);  alloc([1:idxSel-1, idxSel+1:end])];
                end
            end

            ueList = ueList(1:K);
            alloc  = alloc(1:K);

            % Optional: if we drop users, rescale PRB to keep sum<=total
            s = sum(alloc);
            if s > 0
                % keep as-is; sum already <= totalPRB by construction
            end
        end
    end
end
