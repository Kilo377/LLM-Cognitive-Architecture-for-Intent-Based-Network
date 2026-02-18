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
            obj.maxUEPerCell = 4;   % <<< NEW: enforce contention
        end

        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;
            numUE   = ctx.cfg.scenario.numUE;

            if ~isfield(ctx.tmp,'scheduledUE')
                ctx.tmp.scheduledUE = cell(numCell,1);
            end
            if ~isfield(ctx.tmp,'prbAlloc')
                ctx.tmp.prbAlloc = cell(numCell,1);
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


                %------------------print-----------------------
                %if ctx.slot <= 5
                %    fprintf("Slot %d Cell %d UEset=%d\n", ...
                 %       ctx.slot, c, numel(ueSet));
                %end

                % Filter HO-blocked UE
                ueSet = obj.filterHoBlockedUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    continue;
                end

                % Filter empty buffer UE
                ueSet = obj.filterEmptyBufferUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    continue;
                end

                % Action selected UE
                selU = obj.getSelectedUE(ctx, c, numUE, ueSet);

                % Allocate PRB (RR + optional boost), and update rrPtr through ctx
                [ctx, schedUE, prbAlloc] = obj.allocatePRB(ctx, c, ueSet, selU);

                % Aggregate duplicate UE entries (RR chunk may hit same UE multiple times)
                [schedUE, prbAlloc] = obj.aggregateAlloc(schedUE, prbAlloc);

                % Enforce max concurrent UE per cell (contention knob)
                [schedUE, prbAlloc] = obj.enforceMaxUE(schedUE, prbAlloc, selU);

                ctx.tmp.scheduledUE{c} = schedUE(:);
                ctx.tmp.prbAlloc{c}    = prbAlloc(:);


                %------------------print-----------------------
                %if ctx.slot <= 5
                %    fprintf("Slot %d Cell %d scheduled=%d\n", ...
                %        ctx.slot, c, numel(ctx.tmp.scheduledUE{c}));
                %end

            end
        end
    end

    methods (Access = private)

        function ueSet = filterHoBlockedUE(~, ctx, ueSet)
            ok = true(size(ueSet));
            for i = 1:numel(ueSet)
                u = ueSet(i);
                if ctx.slot < ctx.ueBlockedUntilSlot(u)
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

            % Preserve order of first appearance
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
                    % Move selU to front
                    ueList = [ueList(idxSel); ueList([1:idxSel-1, idxSel+1:end])];
                    alloc  = [alloc(idxSel);  alloc([1:idxSel-1, idxSel+1:end])];
                end
            end

            % Keep first K UEs, drop the rest (contention)
            ueList = ueList(1:K);
            alloc  = alloc(1:K);
        end
    end
end
