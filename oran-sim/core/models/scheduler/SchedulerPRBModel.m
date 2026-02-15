classdef SchedulerPRBModel
    properties
        prbChunk    % PRB granularity
        actionBoost % PRB share for selected UE
    end

    methods
        function obj = SchedulerPRBModel()
            obj.prbChunk    = 10;
            obj.actionBoost = 0.6;
        end

        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;
            numUE   = ctx.cfg.scenario.numUE;

            % Ensure fields exist (normally created by ctx.clearSlotTemp)
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

                % Filter HO-blocked UE
                ok = true(size(ueSet));
                for i = 1:numel(ueSet)
                    u = ueSet(i);
                    if ctx.slot < ctx.ueBlockedUntilSlot(u)
                        ok(i) = false;
                    end
                end
                ueSet = ueSet(ok);

                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    continue;
                end

                % Optional: filter empty buffer UE
                ueSet = obj.filterEmptyBufferUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.scheduledUE{c} = [];
                    ctx.tmp.prbAlloc{c}    = [];
                    continue;
                end

                % Action selected UE
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

                % Allocate PRB and update rrPtr through returned ctx
                [ctx, schedUE, prbAlloc] = obj.allocatePRB(ctx, c, ueSet, selU);

                ctx.tmp.scheduledUE{c} = schedUE(:);
                ctx.tmp.prbAlloc{c}    = prbAlloc(:);
            end
        end
    end

    methods (Access = private)

        function ueSet = filterEmptyBufferUE(~, ctx, ueSet)
            keep = false(size(ueSet));
            for i = 1:numel(ueSet)
                u = ueSet(i);
                q = ctx.scenario.traffic.model.getQueue(u);
                keep(i) = ~isempty(q);
            end
            ueSet = ueSet(keep);
        end

        function [ctx, schedUE, prbAlloc] = allocatePRB(obj, ctx, c, ueSet, selU)

            totalPRB = ctx.numPRB;

            % If only one UE
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
    end
end
