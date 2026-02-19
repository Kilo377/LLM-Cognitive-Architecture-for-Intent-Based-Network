classdef SchedulerQoSPRbModel
%SCHEDULERQOSPRBMODEL v2.0 (ctrl-safe + debug + per-cell PRB + QoS+PF)
%
% Output (per slot):
%   ctx.tmp.scheduledUE{c} : [Kx1] UE list (unique after aggregate)
%   ctx.tmp.prbAlloc{c}    : [Kx1] PRB per UE (aligned with scheduledUE)
%
% Policy:
%   1) URLLC urgency first (deadline / urgent count)
%   2) PF for eMBB-like flows (buffer / avgTput)
%   3) mMTC last
%
% Control hook (from ctx.ctrl):
%   ctx.ctrl.selectedUE(c) can reserve actionBoost share for that UE
%   (optional) ctx.ctrl.weightUE(u) can weight UE scoring
%
% Rules:
%   - NEVER read ctx.action
%   - Use ctx.ctrl only
%   - Use ctx.numPRBPerCell(c) if available
%   - Fill ctx.tmp.lastPRBUsedPerCell for Energy/StateBus

    properties
        prbChunk
        actionBoost

        % PF parameters
        pfAlpha
        pfEps
        wUrllc
        wEmbb
        wMmtc

        urgentDeadline_slot

        % safety
        maxUEPerCell

        % debug helper
        debugFirstSlots
    end

    properties (Access = private)
        avgTputBitPerUE
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

            obj.maxUEPerCell = 4;
            obj.debugFirstSlots = 3;
        end

        function obj = init(obj, ctx)
            numUE = ctx.cfg.scenario.numUE;
            obj.avgTputBitPerUE = ones(numUE,1) * 1e4;
            obj.initialized = true;
        end

        function [obj, ctx] = step(obj, ctx)

            if ~obj.initialized
                obj = obj.init(ctx);
            end

            numCell = ctx.cfg.scenario.numCell;
            numUE   = ctx.cfg.scenario.numUE;

            % -------------------------------------------------
            % tmp init
            % -------------------------------------------------
            ctx.tmp.scheduledUE = cell(numCell,1);
            ctx.tmp.prbAlloc    = cell(numCell,1);

            if ~isfield(ctx.tmp,'cell') || isempty(ctx.tmp.cell)
                ctx.tmp.cell = struct();
            end

            if ~isfield(ctx.tmp,'debug') || isempty(ctx.tmp.debug)
                ctx.tmp.debug = struct();
            end
            ctx.tmp.debug.schedulerQos = struct();
            ctx.tmp.debug.schedulerQos.selU = zeros(numCell,1);
            ctx.tmp.debug.schedulerQos.selU_reason = strings(numCell,1);
            ctx.tmp.debug.schedulerQos.cellReason = strings(numCell,1);
            ctx.tmp.debug.schedulerQos.prbTotal = zeros(numCell,1);
            ctx.tmp.debug.schedulerQos.prbUsed  = zeros(numCell,1);

            % -------------------------------------------------
            % PF average update (from last slot served bits)
            % -------------------------------------------------
            if isfield(ctx.tmp,'lastServedBitsPerUE')
                inst = ctx.tmp.lastServedBitsPerUE(:);
                if numel(inst) == numUE
                    obj.avgTputBitPerUE = obj.pfAlpha * obj.avgTputBitPerUE + (1-obj.pfAlpha) * inst;
                end
            end

            % -------------------------------------------------
            % per-cell PRB total
            % -------------------------------------------------
            prbTotalVec = obj.getCellPrbTotal(ctx, numCell);
            ctx.tmp.cell.prbTotal = prbTotalVec(:);
            ctx.tmp.cell.prbUsed  = zeros(numCell,1);

            % -------------------------------------------------
            % Ensure lastPRBUsedPerCell exists
            % -------------------------------------------------
            ctx.tmp.lastPRBUsedPerCell = zeros(numCell,1);

            % -------------------------------------------------
            % Sleep gating (from ctrl)
            % -------------------------------------------------
            cellIsSleeping = false(numCell,1);
            if isprop(ctx,'ctrl') && ~isempty(ctx.ctrl) && isfield(ctx.ctrl,'cellSleepState')
                ss = ctx.ctrl.cellSleepState(:);
                if numel(ss) == numCell
                    cellIsSleeping = (round(ss) >= 1);
                end
            end

            % -------------------------------------------------
            % optional UE weight
            % -------------------------------------------------
            wUE = ones(numUE,1);
            if isprop(ctx,'ctrl') && ~isempty(ctx.ctrl) && isfield(ctx.ctrl,'weightUE')
                v = ctx.ctrl.weightUE(:);
                if numel(v) == numUE
                    wUE = max(v,0);
                end
            end

            % -------------------------------------------------
            % schedule each cell
            % -------------------------------------------------
            for c = 1:numCell

                totalPRB = prbTotalVec(c);
                ctx.tmp.debug.schedulerQos.prbTotal(c) = totalPRB;

                ctx.accPRBTotalPerCell(c) = ctx.accPRBTotalPerCell(c) + totalPRB;

                if totalPRB <= 0
                    ctx.tmp.debug.schedulerQos.cellReason(c) = "totalPRB<=0";
                    continue;
                end

                if cellIsSleeping(c)
                    ctx.tmp.debug.schedulerQos.cellReason(c) = "cellSleeping";
                    continue;
                end

                ueSet = find(ctx.servingCell == c);
                if isempty(ueSet)
                    ctx.tmp.debug.schedulerQos.cellReason(c) = "noUEinCell";
                    continue;
                end

                ueSet = obj.filterBlockedUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.debug.schedulerQos.cellReason(c) = "allBlocked";
                    continue;
                end

                ueSet = obj.filterEmptyBufferUE(ctx, ueSet);
                if isempty(ueSet)
                    ctx.tmp.debug.schedulerQos.cellReason(c) = "allEmptyBuffer";
                    continue;
                end

                [selU, selReason] = obj.getSelectedUE_fromCtrl(ctx, c, ueSet, numUE);
                ctx.tmp.debug.schedulerQos.selU(c) = selU;
                ctx.tmp.debug.schedulerQos.selU_reason(c) = selReason;

                [ueList, prbList] = obj.allocateCell(ctx, ueSet, selU, totalPRB, wUE);

                % aggregate duplicates
                [ueList, prbList] = obj.aggregateAlloc(ueList, prbList);

                % enforce maxUEPerCell
                [ueList, prbList] = obj.enforceMaxUE(ueList, prbList, selU);

                ctx.tmp.scheduledUE{c} = ueList(:);
                ctx.tmp.prbAlloc{c}    = prbList(:);

                prbUsed = sum(prbList);
                prbUsed = min(max(prbUsed,0), totalPRB);

                ctx.tmp.cell.prbUsed(c) = prbUsed;
                ctx.tmp.lastPRBUsedPerCell(c) = prbUsed;

                ctx.accPRBUsedPerCell(c) = ctx.accPRBUsedPerCell(c) + prbUsed;

                ctx.tmp.debug.schedulerQos.prbUsed(c) = prbUsed;

                if ctx.tmp.debug.schedulerQos.cellReason(c) == ""
                    ctx.tmp.debug.schedulerQos.cellReason(c) = "ok";
                end
            end

            % -------------------------------------------------
            % debug print
            % -------------------------------------------------
            if obj.shouldPrint(ctx)
                fprintf('[SchedulerQoS] slot=%d prbUsed=', ctx.slot);
                fprintf(' %.0f', ctx.tmp.lastPRBUsedPerCell);
                fprintf('\n');
            end
        end
    end

    % ==========================================================
    % private
    % ==========================================================
    methods (Access = private)

        function tf = shouldPrint(obj, ctx)
            tf = false;

            if ctx.slot <= obj.debugFirstSlots
                tf = true;
            end

            if isprop(ctx,'debug') && ~isempty(ctx.debug) && isstruct(ctx.debug)
                if isfield(ctx.debug,'enabled') && ctx.debug.enabled
                    if ~isfield(ctx.debug,'models')
                        tf = true;
                        return;
                    end
                    if isfield(ctx.debug.models,'scheduler') && ctx.debug.models.scheduler
                        tf = true;
                        return;
                    end
                end
            end
        end

        function prbTotalVec = getCellPrbTotal(~, ctx, numCell)
            if isprop(ctx,'numPRBPerCell') && numel(ctx.numPRBPerCell) == numCell
                prbTotalVec = ctx.numPRBPerCell(:);
                return;
            end
            prbTotalVec = ctx.numPRB * ones(numCell,1);
        end

        function ueSet = filterBlockedUE(~, ctx, ueSet)
            keep = true(size(ueSet));

            for i = 1:numel(ueSet)
                u = ueSet(i);

                if isprop(ctx,'ueBlockedUntilSlot') && ctx.slot < ctx.ueBlockedUntilSlot(u)
                    keep(i) = false;
                end

                if isprop(ctx,'ueInOutageUntilSlot') && ctx.slot < ctx.ueInOutageUntilSlot(u)
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

        function [selU, reason] = getSelectedUE_fromCtrl(~, ctx, c, ueSet, numUE)

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

        function [ueList, prbList] = allocateCell(obj, ctx, ueSet, selU, totalPRB, wUE)

            prbSel = 0;
            if selU > 0
                prbSel = max(1, floor(totalPRB * obj.actionBoost));
                prbSel = min(prbSel, totalPRB);
            end

            prbRem = totalPRB - prbSel;

            ueList  = [];
            prbList = [];

            if prbSel > 0
                ueList(end+1,1)  = selU; %#ok<AGROW>
                prbList(end+1,1) = prbSel; %#ok<AGROW>
                ueSet = ueSet(ueSet ~= selU);
            end

            if prbRem <= 0 || isempty(ueSet)
                return;
            end

            nChunk = ceil(prbRem / obj.prbChunk);
            prbBudget = prbRem;

            for k = 1:nChunk
                if prbBudget <= 0 || isempty(ueSet)
                    break;
                end

                u = obj.pickUE(ctx, ueSet, wUE);

                prb = min(obj.prbChunk, prbBudget);
                prbBudget = prbBudget - prb;

                ueList(end+1,1)  = u; %#ok<AGROW>
                prbList(end+1,1) = prb; %#ok<AGROW>
            end
        end

        function u = pickUE(obj, ctx, ueSet, wUE)

            score = -inf(size(ueSet));

            for i = 1:numel(ueSet)
                uu = ueSet(i);

                q = ctx.scenario.traffic.model.getQueue(uu);
                if isempty(q)
                    continue;
                end

                [bufBits, urgentCnt, minDL, hasURLLC, hasMMTC] = obj.summarizeQueue(q);

                w = obj.wEmbb;
                if hasURLLC && minDL <= obj.urgentDeadline_slot
                    w = obj.wUrllc;
                elseif hasMMTC && ~hasURLLC
                    w = obj.wMmtc;
                end

                pf = bufBits / max(obj.avgTputBitPerUE(uu), obj.pfEps);
                urgBump = 1 + 0.3*urgentCnt;

                score(i) = w * pf * urgBump * wUE(uu);
            end

            [~, idx] = max(score);
            u = ueSet(idx);
        end

        function [bufBits, urgentCnt, minDL, hasURLLC, hasMMTC] = summarizeQueue(~, q)

            sizes = [q.size];
            bufBits = sum(sizes);

            dl = [q.deadline];

            t = {q.type};
            hasURLLC = any(strcmp(t,'URLLC'));
            hasMMTC  = any(strcmp(t,'mMTC'));

            urgentCnt = sum(isfinite(dl) & dl <= 5);

            if any(isfinite(dl))
                minDL = min(dl(isfinite(dl)));
            else
                minDL = inf;
            end
        end

        function [ue2, prb2] = aggregateAlloc(~, ueList, prbList)

            if isempty(ueList)
                ue2  = ueList;
                prb2 = prbList;
                return;
            end

            ue2  = [];
            prb2 = [];

            for i = 1:numel(ueList)
                u = ueList(i);
                p = prbList(i);

                j = find(ue2 == u, 1);
                if isempty(j)
                    ue2(end+1,1)  = u; %#ok<AGROW>
                    prb2(end+1,1) = p; %#ok<AGROW>
                else
                    prb2(j) = prb2(j) + p;
                end
            end
        end

        function [ueList, prbList] = enforceMaxUE(obj, ueList, prbList, selU)

            if isempty(ueList)
                return;
            end

            K = obj.maxUEPerCell;
            if K <= 0
                ueList = [];
                prbList = [];
                return;
            end

            if numel(ueList) <= K
                return;
            end

            % keep selU first if exists
            if selU > 0
                idxSel = find(ueList == selU, 1);
                if ~isempty(idxSel)
                    ueList = [ueList(idxSel); ueList([1:idxSel-1, idxSel+1:end])];
                    prbList = [prbList(idxSel); prbList([1:idxSel-1, idxSel+1:end])];
                end
            end

            % keep top-K by PRB
            % stable sort by prb desc, keep first K
            [~, ord] = sort(prbList, 'descend');
            ueList = ueList(ord);
            prbList = prbList(ord);

            ueList = ueList(1:K);
            prbList = prbList(1:K);
        end
    end
end
