classdef HandoverModel
%HANDOVERMODEL v4.0: ctrl-only + A3 enter/exit + ping-pong + RLF + debug
%
% Reads:
%   ctx.rsrp_dBm / ctx.sinr_dB / ctx.servingCell / ctx.slot
%   ctx.ctrl.cellSleepState
%   ctx.ctrl.hysteresisOffset_dB (optional)
%   ctx.ctrl.tttOffset_slot      (optional)
%   ctx.ctrl.rlfSinrThresholdOffset_dB (optional scalar)
%
% Writes:
%   ctx.measRsrp_dBm
%   ctx.servingCell
%   ctx.ueBlockedUntilSlot
%   ctx.uePostHoUntilSlot
%   ctx.uePostHoSinrPenalty_dB
%   ctx.ueInOutageUntilSlot
%   ctx.rlfTimer / ctx.hoTimer
%   ctx.tmp.events.{...}
%   ctx.debug.trace.handover (optional)

    properties
        % A3 / HO
        hysteresis_dB
        ttt_slot
        interruption_slot
        postHoPenalty_slot
        postHoSinrPenalty_dB
        minGap_slot

        % Measurement filtering
        measAlpha
        a3EnterMargin_dB
        a3ExitMargin_dB

        % Ping-pong
        pingPongWindow_slot

        % RLF
        rlfSinrThresh_dB
        rlfTTT_slot
        rlfOutage_slot

        moduleName = "handover";
    end

    methods
        function obj = HandoverModel()
            obj.hysteresis_dB        = 3;
            obj.ttt_slot             = 5;

            obj.interruption_slot    = 5;

            obj.postHoPenalty_slot   = 8;
            obj.postHoSinrPenalty_dB = 3;

            obj.minGap_slot          = 10;

            obj.measAlpha            = 0.85;
            obj.a3EnterMargin_dB     = 0.0;
            obj.a3ExitMargin_dB      = 1.0;

            obj.pingPongWindow_slot  = 50;

            obj.rlfSinrThresh_dB     = -6;
            obj.rlfTTT_slot          = 10;
            obj.rlfOutage_slot       = 20;
        end

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            %==================================================
            % 0) Active cell mask (exclude sleeping cells) - ctrl only
            %==================================================
            cellActive = true(numCell,1);
            if isfield(ctx,'ctrl') && isfield(ctx.ctrl,'cellSleepState')
                ss = round(ctx.ctrl.cellSleepState(:));
                if numel(ss) == numCell
                    cellActive = (ss == 0);
                end
            end

            %==================================================
            % 0.1) Control knobs from ctrl (optional)
            %==================================================
            hoOffset = zeros(numCell,1);
            if isfield(ctx,'ctrl') && isfield(ctx.ctrl,'hysteresisOffset_dB')
                v = ctx.ctrl.hysteresisOffset_dB(:);
                if numel(v) == numCell
                    hoOffset = v;
                end
            end
            effectiveHyst = obj.hysteresis_dB + hoOffset;

            tttEff = obj.ttt_slot * ones(numUE,1);
            if isfield(ctx,'ctrl') && isfield(ctx.ctrl,'tttOffset_slot')
                v = ctx.ctrl.tttOffset_slot(:);
                if numel(v) == numCell
                    % apply per-serving-cell offset
                    for u = 1:numUE
                        s = ctx.servingCell(u);
                        if s < 1 || s > numCell
                            s = 1;
                        end
                        tttEff(u) = obj.ttt_slot + v(s);
                    end
                end
            end
            tttEff = max(1, round(tttEff));

            rlfThr = obj.rlfSinrThresh_dB;
            if isfield(ctx,'ctrl') && isfield(ctx.ctrl,'rlfSinrThresholdOffset_dB')
                v = ctx.ctrl.rlfSinrThresholdOffset_dB;
                if isnumeric(v)
                    rlfThr = rlfThr + v;
                end
            end

            %==================================================
            % 1) Events init (tmp)
            %==================================================
            if ~isfield(ctx.tmp,'events') || isempty(ctx.tmp.events)
                ctx.tmp.events = struct();
            end

            ctx.tmp.events.hoOccured        = false;
            ctx.tmp.events.lastHOue         = 0;
            ctx.tmp.events.lastHOfrom       = 0;
            ctx.tmp.events.lastHOto         = 0;

            ctx.tmp.events.pingPongOccured  = false;
            ctx.tmp.events.pingPongCountInc = 0;

            ctx.tmp.events.rlfOccured       = false;
            ctx.tmp.events.rlfUE            = 0;
            ctx.tmp.events.rlfFrom          = 0;
            ctx.tmp.events.rlfTo            = 0;

            %==================================================
            % 2) Ensure state fields exist (RanContext already has most)
            %==================================================
            if isempty(ctx.measRsrp_dBm)
                ctx.measRsrp_dBm = ctx.rsrp_dBm;
            end
            if isempty(ctx.lastHoSlot)
                ctx.lastHoSlot = -inf(numUE,1);
            end
            if isempty(ctx.lastHoFromCell)
                ctx.lastHoFromCell = zeros(numUE,1);
            end
            if isempty(ctx.ueBlockedUntilSlot)
                ctx.ueBlockedUntilSlot = zeros(numUE,1);
            end
            if isempty(ctx.uePostHoUntilSlot)
                ctx.uePostHoUntilSlot = zeros(numUE,1);
            end
            if isempty(ctx.uePostHoSinrPenalty_dB)
                ctx.uePostHoSinrPenalty_dB = zeros(numUE,1);
            end
            if isempty(ctx.rlfTimer)
                ctx.rlfTimer = zeros(numUE,1);
            end
            if isempty(ctx.ueInOutageUntilSlot)
                ctx.ueInOutageUntilSlot = zeros(numUE,1);
            end

            %==================================================
            % 3) Measurement filtering
            %==================================================
            ctx.measRsrp_dBm = obj.measAlpha * ctx.measRsrp_dBm + ...
                               (1-obj.measAlpha) * ctx.rsrp_dBm;

            %==================================================
            % 4) RLF detection + outage handling
            %==================================================
            rlfCountSlot = 0;

            for u = 1:numUE

                if ctx.slot < ctx.ueInOutageUntilSlot(u)
                    ctx.hoTimer(u) = 0;
                    continue;
                end

                if ctx.sinr_dB(u) < rlfThr
                    ctx.rlfTimer(u) = ctx.rlfTimer(u) + 1;
                else
                    ctx.rlfTimer(u) = 0;
                end

                if ctx.rlfTimer(u) >= obj.rlfTTT_slot

                    fromCell = ctx.servingCell(u);

                    ctx.ueInOutageUntilSlot(u) = ctx.slot + obj.rlfOutage_slot;
                    ctx.ueBlockedUntilSlot(u)  = max(ctx.ueBlockedUntilSlot(u), ctx.ueInOutageUntilSlot(u));

                    measRow = ctx.measRsrp_dBm(u,:);
                    measRow(~cellActive') = -inf;
                    [~, bestCell] = max(measRow);

                    if bestCell < 1 || bestCell > numCell
                        bestCell = fromCell;
                    end
                    ctx.servingCell(u) = bestCell;

                    ctx.rlfTimer(u) = 0;
                    ctx.hoTimer(u)  = 0;

                    ctx.uePostHoUntilSlot(u) = max(ctx.uePostHoUntilSlot(u), ctx.slot + obj.postHoPenalty_slot);
                    ctx.uePostHoSinrPenalty_dB(u) = max(ctx.uePostHoSinrPenalty_dB(u), obj.postHoSinrPenalty_dB);

                    ctx.tmp.events.rlfOccured = true;
                    ctx.tmp.events.rlfUE      = u;
                    ctx.tmp.events.rlfFrom    = fromCell;
                    ctx.tmp.events.rlfTo      = bestCell;

                    ctx.accRLFCount = ctx.accRLFCount + 1;
                    rlfCountSlot = rlfCountSlot + 1;

                    continue;
                end
            end
            


            %==================================================
            % 5) A3 + TTT HO
            %==================================================
            hoCountSlot = 0;
            pingPongInc = 0;

            for u = 1:numUE

                if ctx.slot < ctx.ueInOutageUntilSlot(u)
                    continue;
                end

                s = ctx.servingCell(u);
                if s < 1 || s > numCell
                    s = 1;
                end

                % ---- Correct minGap guard: compare with last HO time
                if (ctx.slot - ctx.lastHoSlot(u)) < obj.minGap_slot
                    ctx.hoTimer(u) = 0;
                    continue;
                end

                measRow = ctx.measRsrp_dBm(u,:);
                measRow(~cellActive') = -inf;
                [bestMeas, bestCell] = max(measRow);

                servingMeas = ctx.measRsrp_dBm(u,s);

                enterThr = servingMeas + effectiveHyst(s) + obj.a3EnterMargin_dB;

                if bestCell ~= s && bestMeas >= enterThr

                    ctx.hoTimer(u) = ctx.hoTimer(u) + 1;

                    if ctx.hoTimer(u) >= tttEff(u)

                        fromCell = s;
                        toCell   = bestCell;

                        ctx.servingCell(u) = toCell;
                        ctx.hoTimer(u) = 0;

                        ctx.accHOCount = ctx.accHOCount + 1;
                        hoCountSlot = hoCountSlot + 1;

                        ctx.ueBlockedUntilSlot(u) = max(ctx.ueBlockedUntilSlot(u), ctx.slot + obj.interruption_slot);

                        ctx.uePostHoUntilSlot(u) = max(ctx.uePostHoUntilSlot(u), ctx.slot + obj.postHoPenalty_slot);
                        ctx.uePostHoSinrPenalty_dB(u) = obj.postHoSinrPenalty_dB;

                        if ctx.lastHoFromCell(u) == toCell && (ctx.slot - ctx.lastHoSlot(u) <= obj.pingPongWindow_slot)
                            ctx.tmp.events.pingPongOccured  = true;
                            ctx.tmp.events.pingPongCountInc = ctx.tmp.events.pingPongCountInc + 1;
                            pingPongInc = pingPongInc + 1;
                            ctx.accPingPongCount = ctx.accPingPongCount + 1;
                        end

                        ctx.lastHoFromCell(u) = fromCell;
                        ctx.lastHoSlot(u)     = ctx.slot;

                        ctx.tmp.events.hoOccured  = true;
                        ctx.tmp.events.lastHOue   = u;
                        ctx.tmp.events.lastHOfrom = fromCell;
                        ctx.tmp.events.lastHOto   = toCell;
                    end

                else
                    exitThr = servingMeas + effectiveHyst(s) - obj.a3ExitMargin_dB;
                    if bestCell == s || bestMeas < exitThr
                        ctx.hoTimer(u) = 0;
                    end
                end
            end

            %==================================================
            % 6) Debug trace + optional print
            %==================================================
            ctx = obj.writeDebugTrace(ctx, cellActive, effectiveHyst, rlfThr, hoCountSlot, pingPongInc, rlfCountSlot);

            if obj.shouldPrint(ctx)
                obj.printDebug(ctx);
            end
        end
    end

    %=========================================================
    % Debug helpers
    %=========================================================
    methods (Access = private)

        function ctx = writeDebugTrace(obj, ctx, cellActive, effectiveHyst, rlfThr, hoCountSlot, pingPongInc, rlfCountSlot)

            % ===== must use ctx.tmp.debug =====
            if isempty(ctx.tmp)
                ctx.tmp = struct();
            end
            if ~isfield(ctx.tmp,'debug') || isempty(ctx.tmp.debug)
                ctx.tmp.debug = struct();
            end
            if ~isfield(ctx.tmp.debug,'trace') || isempty(ctx.tmp.debug.trace)
                ctx.tmp.debug.trace = struct();
            end
        
            t = struct();
            t.slot = ctx.slot;
        
            % ---- ctrl snapshot
            t.ctrl = struct();
            if isfield(ctx,'ctrl')
                if isfield(ctx.ctrl,'cellSleepState')
                    t.ctrl.sleepState = ctx.ctrl.cellSleepState(:).';
                end
                if isfield(ctx.ctrl,'hysteresisOffset_dB')
                    t.ctrl.hystOffset = ctx.ctrl.hysteresisOffset_dB(:).';
                end
                if isfield(ctx.ctrl,'tttOffset_slot')
                    t.ctrl.tttOffset = ctx.ctrl.tttOffset_slot(:).';
                end
            end
        
            % ---- derived runtime values
            t.derived = struct();
            t.derived.cellActive    = cellActive(:).';
            t.derived.effectiveHyst = effectiveHyst(:).';
            t.derived.rlfThr_dB     = rlfThr;
        
            % ---- slot events
            t.slotEvents = struct();
            t.slotEvents.hoCount      = hoCountSlot;
            t.slotEvents.pingPongInc  = pingPongInc;
            t.slotEvents.rlfCount     = rlfCountSlot;
        
            % ---- health
            t.health = struct();
            t.health.meanSinr_dB = mean(ctx.sinr_dB);
            t.health.minSinr_dB  = min(ctx.sinr_dB);
            t.health.meanRsrpServing_dBm = localMeanServingRsrp(ctx);
        
            ctx.tmp.debug.trace.(obj.moduleName) = t;
        end

        function tf = shouldPrint(~, ctx)

            tf = false;
        
            if ~isfield(ctx.cfg,'debug'), return; end
            if ~isfield(ctx.cfg.debug,'enable'), return; end
            if ~ctx.cfg.debug.enable, return; end
        
            every = 1;
            if isfield(ctx.cfg.debug,'every') && ctx.cfg.debug.every >= 1
                every = round(ctx.cfg.debug.every);
            end
        
            if mod(ctx.slot, every) ~= 0
                return;
            end
        
            if isfield(ctx.cfg.debug,'modules')
                try
                    ms = string(ctx.cfg.debug.modules);
                    if ~any(ms=="handover") && ~any(ms=="all")
                        return;
                    end
                catch
                end
            end
        
            tf = true;
        end

        

        function printDebug(obj, ctx)

            if ~isfield(ctx.tmp,'debug'), return; end
            if ~isfield(ctx.tmp.debug,'trace'), return; end
            if ~isfield(ctx.tmp.debug.trace,obj.moduleName), return; end
        
            tr = ctx.tmp.debug.trace.(obj.moduleName);
        
            fprintf('[DEBUG][slot=%d][%s] ho=%d pingPongInc=%d rlf=%d meanSINR=%.2f minSINR=%.2f\n', ...
                tr.slot, obj.moduleName, ...
                tr.slotEvents.hoCount, ...
                tr.slotEvents.pingPongInc, ...
                tr.slotEvents.rlfCount, ...
                tr.health.meanSinr_dB, ...
                tr.health.minSinr_dB);
        
            if isfield(tr,'derived')
                fprintf('  cellActive=%s\n', mat2str(tr.derived.cellActive));
                fprintf('  effHyst=%s\n', mat2str(tr.derived.effectiveHyst));
                fprintf('  rlfThr_dB=%.2f\n', tr.derived.rlfThr_dB);
            end
        end



    end
end

%=========================================================
% Local helpers
%=========================================================
function m = localMeanServingRsrp(ctx)
numUE = ctx.cfg.scenario.numUE;
v = zeros(numUE,1);
for u = 1:numUE
    s = ctx.servingCell(u);
    if s < 1 || s > size(ctx.rsrp_dBm,2)
        s = 1;
    end
    v(u) = ctx.rsrp_dBm(u,s);
end
m = mean(v);
end
