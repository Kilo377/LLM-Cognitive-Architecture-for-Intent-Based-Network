classdef ActionApplierModel
% ACTIONAPPLIERMODEL v4.0
%
% Responsibilities:
%   1) Attach action to ctx
%   2) Reset controllable parameters from ctx.baseline each slot
%   3) Apply control knobs in deterministic order
%
% IMPORTANT:
%   - baseline is stored in ctx.baseline (persistent)
%   - NEVER use ctx.tmp.baseline
%   - All runtime values are derived from baseline every slot
%
% Controls supported:
%   radio.bandwidthScale        (per cell, 0~1)
%   power.cellTxPowerOffset_dB  (per cell, offset in dB)
%   energy.basePowerScale       (per cell, scale factor)
%   sleep.cellSleepState        (per cell: 0/1/2)
%   scheduling.selectedUE       (per cell)

    methods

        function obj = ActionApplierModel()
        end

        function ctx = step(~, ctx, action)

            %==================================================
            % 0) Attach action
            %==================================================
            ctx.action = action;

            numCell = ctx.cfg.scenario.numCell;

            %==================================================
            % 1) Reset to baseline (EVERY SLOT, FIRST STEP)
            %==================================================
            % Baseline comes from ctx.baseline (persistent)

            ctx.txPowerCell_dBm    = ctx.baseline.txPowerCell_dBm;
            ctx.numPRBPerCell      = ctx.baseline.numPRBPerCell;
            ctx.bandwidthHzPerCell = ctx.baseline.bandwidthHzPerCell;
            ctx.numPRB             = ctx.baseline.numPRB;   % legacy scalar

            %==================================================
            % 2) If no action → just baseline
            %==================================================
            if isempty(action) || ~isstruct(action)
                ctx.tmp.basePowerScale   = ones(numCell,1);
                ctx.tmp.cellIsSleeping   = zeros(numCell,1);
                ctx.tmp.cellSleepState   = zeros(numCell,1);
                ctx.tmp.selectedUE       = zeros(numCell,1);
                ctx.lastNumPRB           = ctx.numPRB;
                return;
            end

            %==================================================
            % 3) radio.bandwidthScale (per cell)
            %==================================================
            if isfield(action,'radio') && ...
               isfield(action.radio,'bandwidthScale')

                bs = action.radio.bandwidthScale;

                if isnumeric(bs) && numel(bs)==numCell

                    bs = max(min(bs(:),1),0);

                    % Scale PRB per cell
                    ctx.numPRBPerCell = ...
                        max(1, round(ctx.numPRBPerCell .* bs));

                    % Scale bandwidth per cell
                    ctx.bandwidthHzPerCell = ...
                        ctx.bandwidthHzPerCell .* max(bs,1e-3);

                    % Legacy scalar PRB
                    ctx.numPRB = ...
                        max(1, round(mean(ctx.numPRBPerCell)));
                end
            end

            %==================================================
            % 4) power.cellTxPowerOffset_dB (OFFSET semantics)
            %==================================================
            % This is NOT absolute power.
            % It is baseline + offset (static over episode).

            if isfield(action,'power') && ...
               isfield(action.power,'cellTxPowerOffset_dB')

                off = action.power.cellTxPowerOffset_dB;

                if isnumeric(off) && numel(off)==numCell
                    ctx.txPowerCell_dBm = ...
                        ctx.txPowerCell_dBm + off(:);
                end
            end

            %==================================================
            % 5) energy.basePowerScale (ONLY affects energy model)
            %==================================================
            if isfield(action,'energy') && ...
               isfield(action.energy,'basePowerScale')

                s = action.energy.basePowerScale;

                if isnumeric(s) && numel(s)==numCell
                    ctx.tmp.basePowerScale = max(s(:),0.1);
                else
                    ctx.tmp.basePowerScale = ones(numCell,1);
                end
            else
                ctx.tmp.basePowerScale = ones(numCell,1);
            end

            %==================================================
            % 6) sleep control
            %==================================================
            if isfield(action,'sleep') && ...
               isfield(action.sleep,'cellSleepState')

                ss = action.sleep.cellSleepState;

                if isnumeric(ss) && numel(ss)==numCell
                    ss = round(ss(:));
                    ctx.tmp.cellSleepState = ss;
                    ctx.tmp.cellIsSleeping = (ss >= 1);
                else
                    ctx.tmp.cellSleepState = zeros(numCell,1);
                    ctx.tmp.cellIsSleeping = zeros(numCell,1);
                end
            else
                ctx.tmp.cellSleepState = zeros(numCell,1);
                ctx.tmp.cellIsSleeping = zeros(numCell,1);
            end

            %==================================================
            % 6.1) Sleep reduces Tx power (coverage impact)
            %==================================================
            ss = ctx.tmp.cellSleepState;

            sleepPenalty_dB = zeros(numCell,1);
            sleepPenalty_dB(ss==1) = 15;   % light sleep
            sleepPenalty_dB(ss==2) = 35;   % deep sleep

            ctx.txPowerCell_dBm = ...
                ctx.txPowerCell_dBm - sleepPenalty_dB;

            %==================================================
            % 7) scheduling.selectedUE
            %==================================================
            if isfield(action,'scheduling') && ...
               isfield(action.scheduling,'selectedUE')

                sel = action.scheduling.selectedUE;

                if isnumeric(sel) && numel(sel)>=numCell
                    ctx.tmp.selectedUE = sel(:);
                else
                    ctx.tmp.selectedUE = zeros(numCell,1);
                end
            else
                ctx.tmp.selectedUE = zeros(numCell,1);
            end

            %==================================================
            % 8) Save effective PRB (for KPI/observability)
            %==================================================
            ctx.lastNumPRB = ctx.numPRB;

            %==================================================
            % 9) Safety guard (optional but recommended)
            %==================================================
            % Prevent runaway power due to coding mistakes
            ctx.txPowerCell_dBm = ...
                min(max(ctx.txPowerCell_dBm, -50), 80);

            %if ctx.slot <= 5
            %    disp("Slot " + ctx.slot + " txPower:");
            %    disp(ctx.txPowerCell_dBm);
            %end


        end
    end
end
