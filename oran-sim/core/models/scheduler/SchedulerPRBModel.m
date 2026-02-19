classdef SchedulerPRBModel
% SCHEDULERPRBMODEL v6.2 (Fix PRB accounting + unified debug + ctrl-only + RLF safe)
%
% Core fix:
%   - Write PRB usage to ctx.lastPRBUsedPerCell_slot (global runtime)
%   - Accumulate ctx.accPRBUsedPerCell (episode)
%   - Keep ctx.tmp.lastPRBUsedPerCell for per-slot scratch
%
% Reads:
%   ctx.numPRBPerCell
%   ctx.servingCell
%   ctx.rrPtr
%   ctx.ctrl.cellSleepState
%   ctx.ctrl.selectedUE
%   ctx.scenario.traffic.model
%   ctx.ueBlockedUntilSlot
%   ctx.ueInOutageUntilSlot
%
% Writes:
%   ctx.tmp.scheduledUE{c}
%   ctx.tmp.prbAlloc{c}
%   ctx.tmp.cell.*
%   ctx.tmp.lastPRBUsedPerCell
%   ctx.lastPRBUsedPerCell_slot          (IMPORTANT)
%   ctx.accPRBTotalPerCell
%   ctx.accPRBUsedPerCell                (IMPORTANT)
%   ctx.rrPtr
%   ctx.debug.trace.scheduler OR ctx.tmp.debug.trace.scheduler (depending on ctx layout)

    properties
        prbChunk = 10
        actionBoost = 0.6
        maxUEPerCell = 4
        moduleName = "scheduler"
    end

    methods
        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;
            numUE   = ctx.cfg.scenario.numUE;

            %===============================
            % Init per-slot containers
            %===============================
            if isempty(ctx.tmp) || ~isstruct(ctx.tmp)
                ctx.tmp = struct();
            end

            ctx.tmp.scheduledUE = cell(numCell,1);
            ctx.tmp.prbAlloc    = cell(numCell,1);

            if ~isfield(ctx.tmp,'cell') || isempty(ctx.tmp.cell)
                ctx.tmp.cell = struct();
            end

            ctx.tmp.cell.prbTotal     = ctx.numPRBPerCell(:);
            ctx.tmp.cell.prbUsed      = zeros(numCell,1);
            ctx.tmp.cell.schedUECount = zeros(numCell,1);

            ctx.tmp.lastPRBUsedPerCell = zeros(numCell,1);

            %===============================
            % Ensure global runtime/episode fields exist
            %===============================
            if ~isfield(ctx,'lastPRBUsedPerCell_slot') || isempty(ctx.lastPRBUsedPerCell_slot) || numel(ctx.lastPRBUsedPerCell_slot) ~= numCell
                ctx.lastPRBUsedPerCell_slot = zeros(numCell,1);
            end

            if ~isfield(ctx,'accPRBUsedPerCell') || isempty(ctx.accPRBUsedPerCell) || numel(ctx.accPRBUsedPerCell) ~= numCell
                ctx.accPRBUsedPerCell = zeros(numCell,1);
            end

            if ~isfield(ctx,'accPRBTotalPerCell') || isempty(ctx.accPRBTotalPerCell) || numel(ctx.accPRBTotalPerCell) ~= numCell
                ctx.accPRBTotalPerCell = zeros(numCell,1);
            end

            if ~isfield(ctx,'rrPtr') || isempty(ctx.rrPtr) || numel(ctx.rrPtr) ~= numCell
                ctx.rrPtr = ones(numCell,1);
            end

            %===============================
            % Sleep gating (ctrl only)
            %===============================
            cellIsSleeping = false(numCell,1);
            if isfield(ctx,'ctrl') && isfield(ctx.ctrl,'cellSleepState')
                ss = ctx.ctrl.cellSleepState(:);
                if numel(ss) == numCell
                    cellIsSleeping = (ss >= 1);
                end
            end

            %===============================
            % Debug trace container
            %===============================
            slotTrace = struct();
            slotTrace.slot = ctx.slot;
            slotTrace.cell = cell(numCell,1);

            %===============================
            % Per-cell scheduling
            %===============================
            for c = 1:numCell

                traceC = struct();
                totalPRB = ctx.numPRBPerCell(c);

                traceC.totalPRB = totalPRB;
                traceC.reason   = "ok";
                traceC.selectedUE = 0;
                traceC.prbUsed  = 0;
                traceC.numSchedUE = 0;

                % Episode PRB total
                ctx.accPRBTotalPerCell(c) = ctx.accPRBTotalPerCell(c) + totalPRB;

                if totalPRB <= 0
                    traceC.reason = "noPRB";
                    slotTrace.cell{c} = traceC;
                    continue;
                end

                if cellIsSleeping(c)
                    traceC.reason = "sleeping";
                    slotTrace.cell{c} = traceC;
                    continue;
                end

                ueSet = find(ctx.servingCell == c);

                if isempty(ueSet)
                    traceC.reason = "noUE";
                    slotTrace.cell{c} = traceC;
                    continue;
                end

                ueSet = obj.filterUnavailableUE(ctx, ueSet);

                if isempty(ueSet)
                    traceC.reason = "allBlocked";
                    slotTrace.cell{c} = traceC;
                    continue;
                end

                ueSet = obj.filterEmptyBufferUE(ctx, ueSet);

                if isempty(ueSet)
                    traceC.reason = "emptyBuffer";
                    slotTrace.cell{c} = traceC;
                    continue;
                end

                [selU, selReason] = obj.getSelectedUE_fromCtrl(ctx, c, numUE, ueSet);
                traceC.selectedUE = selU;
                traceC.selectedUE_reason = selReason;

                [ctx, schedUE, prbAlloc] = obj.allocatePRB(ctx, c, ueSet, selU, totalPRB);

                [schedUE, prbAlloc] = obj.aggregateAlloc(schedUE, prbAlloc);

                [schedUE, prbAlloc] = obj.enforceMaxUE(schedUE, prbAlloc, selU);

                ctx.tmp.scheduledUE{c} = schedUE(:);
                ctx.tmp.prbAlloc{c}    = prbAlloc(:);

                prbUsed = min(sum(prbAlloc), totalPRB);

                ctx.tmp.cell.prbUsed(c)      = prbUsed;
                ctx.tmp.cell.schedUECount(c) = numel(schedUE);
                ctx.tmp.lastPRBUsedPerCell(c)= prbUsed;

                traceC.prbUsed     = prbUsed;
                traceC.numSchedUE  = numel(schedUE);

                slotTrace.cell{c} = traceC;
            end

            %===============================
            % CRITICAL: finalize PRB usage into global ctx
            %===============================
            ctx.lastPRBUsedPerCell_slot = ctx.tmp.lastPRBUsedPerCell(:);
            ctx.accPRBUsedPerCell       = ctx.accPRBUsedPerCell + ctx.lastPRBUsedPerCell_slot;

            %===============================
            % Write debug trace
            %===============================
            ctx = obj.writeDebugTrace(ctx, slotTrace);

            if obj.shouldPrint(ctx)
                obj.printDebug(ctx);
            end
        end
    end

    %==========================================================
    % Private helpers
    %==========================================================
    methods (Access = private)

        function ueSet = filterUnavailableUE(~, ctx, ueSet)

            ok = true(size(ueSet));

            for i = 1:numel(ueSet)

                u = ueSet(i);

                % HO interruption
                if isfield(ctx,'ueBlockedUntilSlot') && ctx.slot < ctx.ueBlockedUntilSlot(u)
                    ok(i) = false;
                    continue;
                end

                % RLF outage
                if isfield(ctx,'ueInOutageUntilSlot') && ctx.slot < ctx.ueInOutageUntilSlot(u)
                    ok(i) = false;
                    continue;
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

            if ~isfield(ctx,'ctrl') || ~isfield(ctx.ctrl,'selectedUE')
                return;
            end

            sel = ctx.ctrl.selectedUE;

            if numel(sel) < c
                reason = "sizeMismatch";
                return;
            end

            v = round(sel(c));

            if v < 1 || v > numUE
                reason = "outOfRange";
                return;
            end

            if ~any(ueSet == v)
                reason = "notInCell";
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

            ptr = ctx.rrPtr(c);

            while prbBudget > 0

                idx = mod(ptr-1, numel(ueSet)) + 1;
                u   = ueSet(idx);

                prb = min(obj.prbChunk, prbBudget);

                ueList(end+1,1) = u; %#ok<AGROW>
                alloc(end+1,1)  = prb; %#ok<AGROW>

                prbBudget = prbBudget - prb;
                ptr = ptr + 1;
            end

            ctx.rrPtr(c) = ptr;
        end

        function [ueList2, alloc2] = aggregateAlloc(~, ueList, alloc)

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

            if numel(ueList) <= obj.maxUEPerCell
                return;
            end

            if selU > 0
                idxSel = find(ueList == selU, 1);
                if ~isempty(idxSel)
                    ueList = [ueList(idxSel); ueList([1:idxSel-1 idxSel+1:end])];
                    alloc  = [alloc(idxSel);  alloc([1:idxSel-1 idxSel+1:end])];
                end
            end

            ueList = ueList(1:obj.maxUEPerCell);
            alloc  = alloc(1:obj.maxUEPerCell);
        end

        %===============================
        % Debug helpers
        %===============================
        function ctx = writeDebugTrace(obj, ctx, slotTrace)

            % Prefer ctx.debug if RanContext has it. Fallback to ctx.tmp.debug.
            useCtxDebug = isfield(ctx,'debug');

            if useCtxDebug
                if isempty(ctx.debug), ctx.debug = struct(); end
                if ~isfield(ctx.debug,'trace') || isempty(ctx.debug.trace)
                    ctx.debug.trace = struct();
                end
            else
                if isempty(ctx.tmp), ctx.tmp = struct(); end
                if ~isfield(ctx.tmp,'debug') || isempty(ctx.tmp.debug)
                    ctx.tmp.debug = struct();
                end
                if ~isfield(ctx.tmp.debug,'trace') || isempty(ctx.tmp.debug.trace)
                    ctx.tmp.debug.trace = struct();
                end
            end

            t = struct();
            t.slot = ctx.slot;
            t.slotTrace = slotTrace;

            t.runtime = struct();
            t.runtime.lastPRBUsed    = ctx.lastPRBUsedPerCell_slot(:).';
            t.runtime.numPRBPerCell  = ctx.numPRBPerCell(:).';
            t.runtime.prbUsed_tmp    = ctx.tmp.lastPRBUsedPerCell(:).';

            if isfield(ctx,'sinr_dB') && numel(ctx.sinr_dB) > 0
                t.runtime.meanSINR = mean(ctx.sinr_dB);
            end

            if useCtxDebug
                ctx.debug.trace.(obj.moduleName) = t;
            else
                ctx.tmp.debug.trace.(obj.moduleName) = t;
            end
        end

        function tf = shouldPrint(obj, ctx)

            tf = false;

            if ~isfield(ctx.cfg,'debug'), return; end
            if ~isfield(ctx.cfg.debug,'enable'), return; end
            if ~ctx.cfg.debug.enable, return; end

            every = 100;
            if isfield(ctx.cfg.debug,'every') && isnumeric(ctx.cfg.debug.every) && ctx.cfg.debug.every >= 1
                every = round(ctx.cfg.debug.every);
            end

            if mod(ctx.slot, every) ~= 0
                return;
            end

            if isfield(ctx.cfg.debug,'modules')
                try
                    ms = string(ctx.cfg.debug.modules);
                    if ~any(ms==obj.moduleName) && ~any(ms=="all")
                        return;
                    end
                catch
                end
            end

            tf = true;
        end

        function printDebug(obj, ctx)

            tr = [];

            if isfield(ctx,'debug') && isfield(ctx.debug,'trace') && isfield(ctx.debug.trace,obj.moduleName)
                tr = ctx.debug.trace.(obj.moduleName);
            elseif isfield(ctx.tmp,'debug') && isfield(ctx.tmp.debug,'trace') && isfield(ctx.tmp.debug.trace,obj.moduleName)
                tr = ctx.tmp.debug.trace.(obj.moduleName);
            else
                return;
            end

            fprintf('[DEBUG][slot=%d][%s]\n', tr.slot, obj.moduleName);

            if isfield(tr,'runtime')
                fprintf('  PRB used(global)=%s\n', mat2str(tr.runtime.lastPRBUsed));
                fprintf('  PRB used(tmp)   =%s\n', mat2str(tr.runtime.prbUsed_tmp));
                fprintf('  PRB total       =%s\n', mat2str(tr.runtime.numPRBPerCell));
                if isfield(tr.runtime,'meanSINR')
                    fprintf('  meanSINR=%.2f dB\n', tr.runtime.meanSINR);
                end
            end
        end
    end
end

