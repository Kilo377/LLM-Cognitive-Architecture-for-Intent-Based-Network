classdef ActionApplierModel
%ACTIONAPPLIERMODEL Apply action to ctx (stable injection point)
%
% Responsibilities:
% 1) Ensure ctx.action is set every slot
% 2) Apply control knobs that must directly affect kernel state:
%    - radio.bandwidthScale -> ctx.numPRB (relative to baseline)
%    - energy.basePowerScale -> stored for energy model
%    - sleep.cellSleepState -> scheduler gating flag

    methods
        function obj = ActionApplierModel()
        end

        function ctx = step(~, ctx, action)

            % --------------------------------------------------
            % 1) Always write action
            % --------------------------------------------------
            ctx.action = action;

            numCell = ctx.cfg.scenario.numCell;

            % --------------------------------------------------
            % 2) Ensure baseline PRB exists (ONE-TIME init)
            % --------------------------------------------------
            if ~isfield(ctx.tmp,'baseNumPRB')
                ctx.tmp.baseNumPRB = ctx.numPRB;
            end

            % Reset numPRB to baseline every slot
            ctx.numPRB = ctx.tmp.baseNumPRB;

            % --------------------------------------------------
            % 3) bandwidthScale -> effective PRB
            % --------------------------------------------------
            if isfield(action,'radio') && isfield(action.radio,'bandwidthScale')

                bs = action.radio.bandwidthScale;

                if isnumeric(bs) && numel(bs)==numCell

                    % clip scale 0~1
                    bs = max(min(bs(:),1),0);

                    % simple design: average cell scale
                    effScale = mean(bs);

                    ctx.numPRB = max(1, round(ctx.tmp.baseNumPRB * effScale));
                end
            end

            % --------------------------------------------------
            % 4) energy.basePowerScale
            % (do NOT modify txPower directly, energy model reads this)
            % --------------------------------------------------
            if isfield(action,'energy') && isfield(action.energy,'basePowerScale')

                s = action.energy.basePowerScale;

                if isnumeric(s) && numel(s)==numCell
                    ctx.tmp.basePowerScale = max(s(:), 0.1);
                end
            end

            % --------------------------------------------------
            % 5) sleep gating
            % --------------------------------------------------
            if isfield(action,'sleep') && isfield(action.sleep,'cellSleepState')

                ss = action.sleep.cellSleepState;

                if isnumeric(ss) && numel(ss)==numCell
                    ctx.tmp.cellIsSleeping = (round(ss(:)) >= 1);
                end
            end
        end
    end
end
