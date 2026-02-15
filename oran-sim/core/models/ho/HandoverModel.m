classdef HandoverModel
%HANDOVERMODEL v3: L3 filtering + A3 enter/exit + ping-pong + RLF
%
% RLF model:
%   - If SINR stays below threshold for rlfTTT_slot slots -> RLF
%   - UE enters outage for rlfOutage_slot slots (blocked)
%   - UE then force reselects to best measured cell
%
% Events:
%   ctx.tmp.events.hoOccured / pingPongOccured
%   ctx.tmp.events.rlfOccured / rlfUE / rlfFrom / rlfTo

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

            % RLF params (你可以后续扫参)
            obj.rlfSinrThresh_dB     = -6;   % RLF threshold
            obj.rlfTTT_slot          = 10;   % must be bad for 10 slots
            obj.rlfOutage_slot       = 20;   % outage duration after RLF
        end

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            %% -------- events init --------
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

            %% -------- hysteresis offsets from action --------
            hoOffset = zeros(numCell,1);
            if ~isempty(ctx.action) && isfield(ctx.action,'handover') && ...
                    isfield(ctx.action.handover,'hysteresisOffset_dB')
                v = ctx.action.handover.hysteresisOffset_dB;
                if isnumeric(v) && numel(v)==numCell
                    hoOffset = v(:);
                end
            end
            effectiveHyst = obj.hysteresis_dB + hoOffset;

            %% -------- ensure persistent fields exist --------
            if ~isfield(ctx,'measRsrp_dBm') || isempty(ctx.measRsrp_dBm)
                ctx.measRsrp_dBm = ctx.rsrp_dBm;
            end
            if ~isfield(ctx,'lastHoFromCell') || isempty(ctx.lastHoFromCell)
                ctx.lastHoFromCell = zeros(numUE,1);
            end
            if ~isfield(ctx,'lastHoSlot') || isempty(ctx.lastHoSlot)
                ctx.lastHoSlot = -inf(numUE,1);
            end
            if ~isfield(ctx,'ueBlockedUntilSlot') || isempty(ctx.ueBlockedUntilSlot)
                ctx.ueBlockedUntilSlot = zeros(numUE,1);
            end
            if ~isfield(ctx,'uePostHoUntilSlot') || isempty(ctx.uePostHoUntilSlot)
                ctx.uePostHoUntilSlot = zeros(numUE,1);
            end
            if ~isfield(ctx,'uePostHoSinrPenalty_dB') || isempty(ctx.uePostHoSinrPenalty_dB)
                ctx.uePostHoSinrPenalty_dB = zeros(numUE,1);
            end

            % RLF state
            if ~isfield(ctx,'rlfTimer') || isempty(ctx.rlfTimer)
                ctx.rlfTimer = zeros(numUE,1);
            end
            if ~isfield(ctx,'ueInOutageUntilSlot') || isempty(ctx.ueInOutageUntilSlot)
                ctx.ueInOutageUntilSlot = zeros(numUE,1);
            end

            %% -------- 1) measurement filtering --------
            ctx.measRsrp_dBm = obj.measAlpha * ctx.measRsrp_dBm + ...
                               (1-obj.measAlpha) * ctx.rsrp_dBm;

            %% -------- 2) RLF detection + outage handling --------
            for u = 1:numUE

                % If UE is in outage, keep it blocked and skip HO logic
                if ctx.slot < ctx.ueInOutageUntilSlot(u)
                    ctx.hoTimer(u) = 0;
                    continue;
                end

                % RLF timer update (use serving SINR)
                if ctx.sinr_dB(u) < obj.rlfSinrThresh_dB
                    ctx.rlfTimer(u) = ctx.rlfTimer(u) + 1;
                else
                    ctx.rlfTimer(u) = 0;
                end

                % RLF trigger
                if ctx.rlfTimer(u) >= obj.rlfTTT_slot

                    fromCell = ctx.servingCell(u);

                    % Start outage
                    ctx.ueInOutageUntilSlot(u) = ctx.slot + obj.rlfOutage_slot;

                    % Also block user-plane (reusing same blocked flag is ok)
                    ctx.ueBlockedUntilSlot(u) = max(ctx.ueBlockedUntilSlot(u), ctx.ueInOutageUntilSlot(u));

                    % Force reselection to best measured cell
                    [~, bestCell] = max(ctx.measRsrp_dBm(u,:));
                    if bestCell < 1 || bestCell > numCell
                        bestCell = fromCell;
                    end
                    ctx.servingCell(u) = bestCell;

                    % Reset timers
                    ctx.rlfTimer(u) = 0;
                    ctx.hoTimer(u)  = 0;

                    % Post-RLF penalty (stronger than normal HO)
                    ctx.uePostHoUntilSlot(u) = max(ctx.uePostHoUntilSlot(u), ctx.slot + obj.postHoPenalty_slot);
                    ctx.uePostHoSinrPenalty_dB(u) = max(ctx.uePostHoSinrPenalty_dB(u), obj.postHoSinrPenalty_dB);

                    % Event log
                    ctx.tmp.events.rlfOccured = true;
                    ctx.tmp.events.rlfUE      = u;
                    ctx.tmp.events.rlfFrom    = fromCell;
                    ctx.tmp.events.rlfTo      = bestCell;

                    % Optional counter (你如果要就加到 ctx 里)
                    if isfield(ctx,'accRLFCount')
                        ctx.accRLFCount = ctx.accRLFCount + 1;
                    end

                    % continue to next UE
                    continue;
                end
            end

            %% -------- 3) A3 + TTT HO --------
            for u = 1:numUE

                % If in outage, do nothing
                if ctx.slot < ctx.ueInOutageUntilSlot(u)
                    continue;
                end

                s = ctx.servingCell(u);

                % Guard: avoid too frequent HO
                if ctx.slot < (ctx.ueBlockedUntilSlot(u) + obj.minGap_slot)
                    ctx.hoTimer(u) = 0;
                    continue;
                end

                [bestMeas, bestCell] = max(ctx.measRsrp_dBm(u,:));
                servingMeas = ctx.measRsrp_dBm(u,s);

                enterThr = servingMeas + effectiveHyst(s) + obj.a3EnterMargin_dB;

                if bestCell ~= s && bestMeas >= enterThr

                    ctx.hoTimer(u) = ctx.hoTimer(u) + 1;

                    if ctx.hoTimer(u) >= obj.ttt_slot

                        fromCell = s;
                        toCell   = bestCell;

                        ctx.servingCell(u) = toCell;
                        ctx.hoTimer(u) = 0;
                        ctx.accHOCount = ctx.accHOCount + 1;

                        % interruption
                        ctx.ueBlockedUntilSlot(u) = max(ctx.ueBlockedUntilSlot(u), ctx.slot + obj.interruption_slot);

                        % post-HO penalty
                        ctx.uePostHoUntilSlot(u) = max(ctx.uePostHoUntilSlot(u), ctx.slot + obj.postHoPenalty_slot);
                        ctx.uePostHoSinrPenalty_dB(u) = obj.postHoSinrPenalty_dB;

                        % ping-pong detection
                        if ctx.lastHoFromCell(u) == toCell && (ctx.slot - ctx.lastHoSlot(u) <= obj.pingPongWindow_slot)
                            ctx.tmp.events.pingPongOccured  = true;
                            ctx.tmp.events.pingPongCountInc = ctx.tmp.events.pingPongCountInc + 1;
                        end

                        % record last HO
                        ctx.lastHoFromCell(u) = fromCell;
                        ctx.lastHoSlot(u)     = ctx.slot;

                        % event log
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
        end
    end
end
