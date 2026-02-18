classdef ActionApplierModel
% ACTIONAPPLIERMODEL v5.0 (Unified ctrl Architecture)
%
% Architecture:
%   - Baseline stored in ctx.baseline (persistent)
%   - Persistent control stored in ctx.ctrl
%   - Runtime knobs reset from baseline every slot
%   - ctrl is NOT cleared by nextSlot()
%
% NEVER:
%   - Use ctx.tmp for persistent control
%   - Let EnergyModel read ctx.action
%
% Controls:
%   radio.bandwidthScale        [numCell x 1]
%   power.cellTxPowerOffset_dB  [numCell x 1]
%   energy.basePowerScale       [numCell x 1]
%   sleep.cellSleepState        [0/1/2 per cell]
%   scheduling.selectedUE       [numCell x 1]

    methods

        function obj = ActionApplierModel()
        end


        function ctx = step(~, ctx, action)

            numCell = ctx.cfg.scenario.numCell;

            %% =====================================================
            % 0) Attach action
            %% =====================================================
            ctx.action = action;

            %% =====================================================
            % 1) Ensure ctrl exists (persistent control state)
            %% =====================================================
            if ~isfield(ctx,'ctrl') || isempty(ctx.ctrl)

                ctx.ctrl = struct();
                ctx.ctrl.bandwidthScale   = ones(numCell,1);
                ctx.ctrl.txPowerOffset_dB = zeros(numCell,1);
                ctx.ctrl.basePowerScale   = ones(numCell,1);
                ctx.ctrl.cellSleepState   = zeros(numCell,1);
                ctx.ctrl.selectedUE       = zeros(numCell,1);
            end

            %% =====================================================
            % 2) Update ctrl from action (if provided)
            %% =====================================================
            if ~isempty(action) && isstruct(action)

                % -------- radio.bandwidthScale --------
                if isfield(action,'radio') && ...
                   isfield(action.radio,'bandwidthScale')

                    bs = action.radio.bandwidthScale;

                    if isnumeric(bs) && numel(bs)==numCell
                        ctx.ctrl.bandwidthScale = ...
                            max(min(bs(:),1),0);
                    end
                end

                % -------- power offset --------
                if isfield(action,'power') && ...
                   isfield(action.power,'cellTxPowerOffset_dB')

                    off = action.power.cellTxPowerOffset_dB;

                    if isnumeric(off) && numel(off)==numCell
                        ctx.ctrl.txPowerOffset_dB = off(:);
                    end
                end

                % -------- energy scale --------
                if isfield(action,'energy') && ...
                   isfield(action.energy,'basePowerScale')

                    s = action.energy.basePowerScale;

                    if isnumeric(s) && numel(s)==numCell
                        ctx.ctrl.basePowerScale = max(s(:),0.1);
                    end
                end

                % -------- sleep --------
                if isfield(action,'sleep') && ...
                   isfield(action.sleep,'cellSleepState')

                    ss = action.sleep.cellSleepState;

                    if isnumeric(ss) && numel(ss)==numCell
                        ctx.ctrl.cellSleepState = ...
                            min(max(round(ss(:)),0),2);
                    end
                end

                % -------- scheduling --------
                if isfield(action,'scheduling') && ...
                   isfield(action.scheduling,'selectedUE')

                    sel = action.scheduling.selectedUE;

                    if isnumeric(sel) && numel(sel)>=numCell
                        ctx.ctrl.selectedUE = sel(:);
                    end
                end
            end

            


            %% =====================================================
            % 3) Reset runtime radio knobs from baseline
            %% =====================================================
            ctx.txPowerCell_dBm    = ctx.baseline.txPowerCell_dBm;
            ctx.numPRBPerCell      = ctx.baseline.numPRBPerCell;
            ctx.bandwidthHzPerCell = ctx.baseline.bandwidthHzPerCell;
            ctx.numPRB             = ctx.baseline.numPRB;

            %% =====================================================
            % 4) Apply bandwidthScale (from ctrl)
            %% =====================================================
            bs = ctx.ctrl.bandwidthScale;

            ctx.numPRBPerCell = ...
                max(1, round(ctx.numPRBPerCell .* bs));

            ctx.bandwidthHzPerCell = ...
                ctx.bandwidthHzPerCell .* max(bs,1e-3);

            ctx.numPRB = ...
                max(1, round(mean(ctx.numPRBPerCell)));

            %% =====================================================
            % 5) Apply Tx power offset
            %% =====================================================
            ctx.txPowerCell_dBm = ...
                ctx.txPowerCell_dBm + ctx.ctrl.txPowerOffset_dB;

            %% =====================================================
            % 6) Apply sleep penalty to coverage
            %% =====================================================
            ss = ctx.ctrl.cellSleepState;

            sleepPenalty_dB = zeros(numCell,1);
            sleepPenalty_dB(ss==1) = 15;
            sleepPenalty_dB(ss==2) = 35;

            ctx.txPowerCell_dBm = ...
                ctx.txPowerCell_dBm - sleepPenalty_dB;

            %% =====================================================
            % 7) Safety clamp
            %% =====================================================
            ctx.txPowerCell_dBm = ...
                min(max(ctx.txPowerCell_dBm,-50),80);

            %% =====================================================
            % 8) Expose scheduling to tmp (scheduler reads tmp)
            %% =====================================================
            ctx.tmp.selectedUE = ctx.ctrl.selectedUE;

            %% =====================================================
            % 9) Save PRB for observability
            %% =====================================================
            ctx.lastNumPRB = ctx.numPRB;

        end
    end
end
