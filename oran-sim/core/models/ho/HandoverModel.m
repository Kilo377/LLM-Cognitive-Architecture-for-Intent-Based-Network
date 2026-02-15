classdef HandoverModel
%HANDOVERMODEL A3+TTT handover with interruption + post-HO penalty
%
% Improvements:
% 1) HO interruption: block user-plane for N slots after HO completes
% 2) Post-HO SINR penalty window: apply additional SINR penalty for M slots
% 3) Event logging: last HO ue/from/to + flag for energy/kpi/state

    properties
        hysteresis_dB
        ttt_slot

        interruption_slot        % user-plane interruption duration (slots)

        postHoPenalty_slot       % penalty window after HO (slots)
        postHoSinrPenalty_dB     % SINR penalty value (dB)

        minGap_slot              % minimum gap between consecutive HOs per UE (slots)
    end

    methods
        function obj = HandoverModel()
            obj.hysteresis_dB        = 3;
            obj.ttt_slot             = 5;

            obj.interruption_slot    = 5;   % stronger than before

            obj.postHoPenalty_slot   = 8;   % e.g. 8 ms
            obj.postHoSinrPenalty_dB = 3;   % subtract 3 dB during window

            obj.minGap_slot          = 10;  % anti ping-pong guard
        end

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            % Ensure events struct exists
            if ~isfield(ctx.tmp,'events') || isempty(ctx.tmp.events)
                ctx.tmp.events = struct();
            end
            ctx.tmp.events.hoOccured = false;
            ctx.tmp.events.lastHOue  = 0;
            ctx.tmp.events.lastHOfrom = 0;
            ctx.tmp.events.lastHOto   = 0;

            % Read xApp hysteresis offsets
            hoOffset = zeros(numCell,1);

            if ~isempty(ctx.action) && isfield(ctx.action,'handover') && ...
                    isfield(ctx.action.handover,'hysteresisOffset_dB')
                v = ctx.action.handover.hysteresisOffset_dB;
                if isnumeric(v) && numel(v) == numCell
                    hoOffset = v(:);
                end
            end

            effectiveHyst = obj.hysteresis_dB + hoOffset;

            % Make sure new fields exist (for backward compatibility)
            if ~isfield(ctx,'uePostHoUntilSlot') || isempty(ctx.uePostHoUntilSlot)
                ctx.uePostHoUntilSlot = zeros(numUE,1);
            end
            if ~isfield(ctx,'uePostHoSinrPenalty_dB') || isempty(ctx.uePostHoSinrPenalty_dB)
                ctx.uePostHoSinrPenalty_dB = zeros(numUE,1);
            end
            if ~isfield(ctx,'ueBlockedUntilSlot') || isempty(ctx.ueBlockedUntilSlot)
                ctx.ueBlockedUntilSlot = zeros(numUE,1);
            end

            for u = 1:numUE

                s = ctx.servingCell(u);

                % Guard: prevent too-frequent HOs (ping-pong reduction)
                if ctx.slot < (ctx.ueBlockedUntilSlot(u) + obj.minGap_slot)
                    ctx.hoTimer(u) = 0;
                    continue;
                end

                [bestRSRP, bestCell] = max(ctx.rsrp_dBm(u,:));

                thr = effectiveHyst(s);

                if bestCell ~= s && (bestRSRP - ctx.rsrp_dBm(u,s) >= thr)

                    ctx.hoTimer(u) = ctx.hoTimer(u) + 1;

                    if ctx.hoTimer(u) >= obj.ttt_slot

                        fromCell = ctx.servingCell(u);
                        toCell   = bestCell;

                        % Execute HO
                        ctx.servingCell(u) = toCell;
                        ctx.hoTimer(u) = 0;
                        ctx.accHOCount = ctx.accHOCount + 1;

                        % HO interruption (block user-plane)
                        ctx.ueBlockedUntilSlot(u) = ...
                            max(ctx.ueBlockedUntilSlot(u), ctx.slot + obj.interruption_slot);

                        % Post-HO penalty window (radio imperfection)
                        ctx.uePostHoUntilSlot(u) = ...
                            max(ctx.uePostHoUntilSlot(u), ctx.slot + obj.postHoPenalty_slot);

                        ctx.uePostHoSinrPenalty_dB(u) = obj.postHoSinrPenalty_dB;

                        % Event log
                        ctx.tmp.events.hoOccured  = true;
                        ctx.tmp.events.lastHOue   = u;
                        ctx.tmp.events.lastHOfrom = fromCell;
                        ctx.tmp.events.lastHOto   = toCell;
                    end
                else
                    ctx.hoTimer(u) = 0;
                end
            end
        end
    end
end
