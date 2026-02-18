classdef ActionApplierModel
%ACTIONAPPLIERMODEL
%
% Responsibilities:
%   1) Always attach action to ctx
%   2) Reset controllable parameters to baseline each slot
%   3) Apply control knobs in a clean, modular way
%
% Controls:
%   radio.bandwidthScale
%   power.cellTxPowerOffset_dB
%   energy.basePowerScale
%   sleep.cellSleepState
%   scheduling.selectedUE
%
% Design rule:
%   - Never permanently overwrite baseline
%   - Always derive from stored baseline
%   - Only modify ctx / ctx.tmp, not other models directly

    methods
        function obj = ActionApplierModel()
        end

        function ctx = step(~, ctx, action)

            %==================================================
            % 0) Attach action
            %==================================================
            ctx.action = action;

            numCell = ctx.cfg.scenario.numCell;

            if isempty(action)
                return;
            end

            %==================================================
            % 1) Ensure baseline values exist (one-time init)
            %==================================================
            if ~isfield(ctx.tmp,'baseline')
                ctx.tmp.baseline = struct();
            end

            % ---- baseline PRB ----
            if ~isfield(ctx.tmp.baseline,'numPRB')
                ctx.tmp.baseline.numPRB = ctx.numPRB;
            end

            % ---- baseline txPower ----
            if ~isfield(ctx.tmp.baseline,'txPowerCell_dBm')
                ctx.tmp.baseline.txPowerCell_dBm = ctx.txPowerCell_dBm;
            end

            %==================================================
            % 2) Reset to baseline (every slot)
            %==================================================
            ctx.numPRB            = ctx.tmp.baseline.numPRB;
            ctx.txPowerCell_dBm   = ctx.tmp.baseline.txPowerCell_dBm;

            %==================================================
            % 3) Apply radio.bandwidthScale
            %==================================================
            if isfield(action,'radio') && ...
               isfield(action.radio,'bandwidthScale')

                bs = action.radio.bandwidthScale;

                if isnumeric(bs) && numel(bs)==numCell
                    bs = max(min(bs(:),1),0);

                    effScale = mean(bs);

                    ctx.numPRB = max(1, ...
                        round(ctx.tmp.baseline.numPRB * effScale));
                end
            end

            %==================================================
            % 4) Apply power offset (affects SINR)
            %==================================================
            if isfield(action,'power') && ...
               isfield(action.power,'cellTxPowerOffset_dB')

                off = action.power.cellTxPowerOffset_dB;

                if isnumeric(off) && numel(off)==numCell
                    ctx.txPowerCell_dBm = ...
                        ctx.txPowerCell_dBm + off(:);
                end
            end

            %==================================================
            % 5) Apply energy.basePowerScale
            % (EnergyModel reads this)
            %==================================================
            if isfield(action,'energy') && ...
               isfield(action.energy,'basePowerScale')

                s = action.energy.basePowerScale;

                if isnumeric(s) && numel(s)==numCell
                    ctx.tmp.basePowerScale = max(s(:),0.1);
                end
            else
                ctx.tmp.basePowerScale = ones(numCell,1);
            end

            %==================================================
            % 6) Apply sleep control
            %==================================================
            if isfield(action,'sleep') && ...
               isfield(action.sleep,'cellSleepState')

                ss = action.sleep.cellSleepState;

                if isnumeric(ss) && numel(ss)==numCell
                    ctx.tmp.cellIsSleeping = ...
                        (round(ss(:)) >= 1);
                    ctx.tmp.cellSleepState = round(ss(:));
                end
            else
                ctx.tmp.cellIsSleeping = zeros(numCell,1);
                ctx.tmp.cellSleepState = zeros(numCell,1);
            end

            %==================================================
            % 7) Scheduler selected UE passthrough
            %==================================================
            if isfield(action,'scheduling') && ...
               isfield(action.scheduling,'selectedUE')

                sel = action.scheduling.selectedUE;

                if isnumeric(sel) && numel(sel)>=numCell
                    ctx.tmp.selectedUE = sel(:);
                end
            else
                ctx.tmp.selectedUE = zeros(numCell,1);
            end

            %==================================================
            % 8) Save last effective PRB (for KPI)
            %==================================================
            ctx.lastNumPRB = ctx.numPRB;

        end
    end
end
