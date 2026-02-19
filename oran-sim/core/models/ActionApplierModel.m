classdef ActionApplierModel
% ACTIONAPPLIERMODEL v6.1 (Action->Ctrl single gate + tmp.debug trace)
%
% Fix:
%   - RanContext is classdef, cannot dynamically add ctx.debug.
%   - All debug info MUST go to ctx.tmp.debug (slot scratch).
%
% Rules:
%   - Models must NOT read ctx.action.
%   - ActionApplier is the ONLY translator: action -> ctrl -> runtime knobs.
%   - ctrl is persistent.
%   - Some ctrl fields are slot-only and are reset every slot.
%   - tmp must NOT carry control state. tmp.debug is allowed (observability only).

    properties
        moduleName = "actionApplier";
    end

    methods
        function obj = ActionApplierModel()
        end

        function ctx = step(obj, ctx, action)

            numCell = ctx.cfg.scenario.numCell;
            numUE   = ctx.cfg.scenario.numUE;

            %=====================================================
            % 0) Ensure ctrl exists (persistent)
            %=====================================================
            if isempty(ctx.ctrl)
                ctx.ctrl = obj.initCtrl(numCell, numUE);
            else
                ctx.ctrl = obj.ensureCtrlFields(ctx.ctrl, numCell, numUE);
            end

            %=====================================================
            % 1) Reset slot-only ctrl fields (avoid stale control)
            %=====================================================
            ctx.ctrl.selectedUE = zeros(numCell,1);
            ctx.ctrl.weightUE   = ones(numUE,1);
            ctx.ctrl.ueBeamId   = zeros(numUE,1);

            %=====================================================
            % 2) Decode action -> ctrl
            %=====================================================
            hasAction = (~isempty(action) && isstruct(action));
            if hasAction
                ctx.ctrl = obj.decodeActionToCtrl(ctx.ctrl, action, numCell, numUE);
            end

            % derived convenience flag
            ss = round(ctx.ctrl.cellSleepState(:));
            ss = min(max(ss,0),2);
            ctx.ctrl.cellSleepState = ss;
            ctx.ctrl.cellIsSleeping = double(ss >= 1);

            %=====================================================
            % 3) Reset runtime knobs from baseline (single source)
            %=====================================================
            ctx.txPowerCell_dBm    = ctx.baseline.txPowerCell_dBm(:);
            ctx.numPRBPerCell      = ctx.baseline.numPRBPerCell(:);
            ctx.bandwidthHzPerCell = ctx.baseline.bandwidthHzPerCell(:);

            ctx.numPRB       = ctx.baseline.numPRB;
            ctx.bandwidthHz  = ctx.baseline.bandwidthHz;
            ctx.noiseFigure_dB = ctx.baseline.noiseFigure_dB;

            %=====================================================
            % 4) Apply RADIO ctrl: bandwidthScale -> PRB + BW
            %=====================================================
            bs = ctx.ctrl.bandwidthScale(:);
            if numel(bs) ~= numCell
                bs = ones(numCell,1);
            end
            bs = min(max(bs,0),1);

            ctx.numPRBPerCell = max(1, round(ctx.numPRBPerCell .* bs));
            ctx.bandwidthHzPerCell = max(1e3, ctx.bandwidthHzPerCell .* max(bs,1e-3));

            ctx.numPRB      = max(1, round(mean(ctx.numPRBPerCell)));
            ctx.bandwidthHz = max(1e3, mean(ctx.bandwidthHzPerCell));

            if ismethod(ctx,'refreshNoise')
                ctx = ctx.refreshNoise();
            end

            %=====================================================
            % 5) Apply POWER ctrl: txPowerOffset_dB
            %=====================================================
            off = ctx.ctrl.txPowerOffset_dB(:);
            if numel(off) ~= numCell
                off = zeros(numCell,1);
            end
            off = min(max(off,-10),10);
            ctx.txPowerCell_dBm = ctx.txPowerCell_dBm + off;

            %=====================================================
            % 6) Apply SLEEP ctrl: coverage penalty via Tx power reduction
            %=====================================================
            sleepPenalty_dB = zeros(numCell,1);
            sleepPenalty_dB(ss==1) = 15;
            sleepPenalty_dB(ss==2) = 35;

            ctx.txPowerCell_dBm = ctx.txPowerCell_dBm - sleepPenalty_dB;

            %=====================================================
            % 7) Safety clamps
            %=====================================================
            ctx.txPowerCell_dBm = min(max(ctx.txPowerCell_dBm,-50),80);

            %=====================================================
            % 8) Observability cache
            %=====================================================
            ctx.lastNumPRB = ctx.numPRB;

            %=====================================================
            % 9) Debug trace + print (MUST use ctx.tmp.debug)
            %=====================================================
            ctx = obj.writeDebugTrace(ctx, hasAction);
            if obj.shouldPrint(ctx)
                obj.printDebug(ctx);
            end
        end
    end

    %=========================================================
    % Private helpers
    %=========================================================
    methods (Access = private)

        function ctrl = initCtrl(~, numCell, numUE)
            ctrl = struct();

            % persistent controls
            ctrl.bandwidthScale   = ones(numCell,1);
            ctrl.txPowerOffset_dB = zeros(numCell,1);
            ctrl.basePowerScale   = ones(numCell,1);
            ctrl.cellSleepState   = zeros(numCell,1);

            % slot-only controls
            ctrl.selectedUE = zeros(numCell,1);
            ctrl.weightUE   = ones(numUE,1);
            ctrl.ueBeamId   = zeros(numUE,1);

            % derived
            ctrl.cellIsSleeping = zeros(numCell,1);

            % future-proof buckets (persistent)
            ctrl.hysteresisOffset_dB = zeros(numCell,1);
            ctrl.tttOffset_slot      = zeros(numCell,1);
            ctrl.rlfSinrThresholdOffset_dB = 0;
        end

        function ctrl = ensureCtrlFields(obj, ctrl, numCell, numUE)
            d = obj.initCtrl(numCell, numUE);
            f = fieldnames(d);
            for i = 1:numel(f)
                k = f{i};
                if ~isfield(ctrl,k) || isempty(ctrl.(k))
                    ctrl.(k) = d.(k);
                end
            end

            % shape guard (avoid silent dimension drift)
            if ~isvector(ctrl.bandwidthScale) || numel(ctrl.bandwidthScale) ~= numCell
                ctrl.bandwidthScale = ones(numCell,1);
            end
            if ~isvector(ctrl.txPowerOffset_dB) || numel(ctrl.txPowerOffset_dB) ~= numCell
                ctrl.txPowerOffset_dB = zeros(numCell,1);
            end
            if ~isvector(ctrl.basePowerScale) || numel(ctrl.basePowerScale) ~= numCell
                ctrl.basePowerScale = ones(numCell,1);
            end
            if ~isvector(ctrl.cellSleepState) || numel(ctrl.cellSleepState) ~= numCell
                ctrl.cellSleepState = zeros(numCell,1);
            end
            if ~isvector(ctrl.selectedUE) || numel(ctrl.selectedUE) ~= numCell
                ctrl.selectedUE = zeros(numCell,1);
            end
            if ~isvector(ctrl.weightUE) || numel(ctrl.weightUE) ~= numUE
                ctrl.weightUE = ones(numUE,1);
            end
            if ~isvector(ctrl.ueBeamId) || numel(ctrl.ueBeamId) ~= numUE
                ctrl.ueBeamId = zeros(numUE,1);
            end
        end

        function ctrl = decodeActionToCtrl(~, ctrl, action, numCell, numUE)

            % radio.bandwidthScale
            if isfield(action,'radio') && isfield(action.radio,'bandwidthScale')
                bs = action.radio.bandwidthScale;
                if isnumeric(bs) && numel(bs) == numCell
                    ctrl.bandwidthScale = min(max(bs(:),0),1);
                end
            end

            % power.cellTxPowerOffset_dB
            if isfield(action,'power') && isfield(action.power,'cellTxPowerOffset_dB')
                off = action.power.cellTxPowerOffset_dB;
                if isnumeric(off) && numel(off) == numCell
                    ctrl.txPowerOffset_dB = min(max(off(:),-10),10);
                end
            end

            % energy.basePowerScale
            if isfield(action,'energy') && isfield(action.energy,'basePowerScale')
                s = action.energy.basePowerScale;
                if isnumeric(s) && numel(s) == numCell
                    ctrl.basePowerScale = min(max(s(:),0.2),1.2);
                end
            end

            % sleep.cellSleepState
            if isfield(action,'sleep') && isfield(action.sleep,'cellSleepState')
                ss = action.sleep.cellSleepState;
                if isnumeric(ss) && numel(ss) == numCell
                    ctrl.cellSleepState = min(max(round(ss(:)),0),2);
                end
            end

            % scheduling.selectedUE (slot-only)
            if isfield(action,'scheduling') && isfield(action.scheduling,'selectedUE')
                sel = action.scheduling.selectedUE;
                if isnumeric(sel) && numel(sel) == numCell
                    ctrl.selectedUE = max(round(sel(:)),0);
                end
            end

            % scheduling.weightUE (slot-only)
            if isfield(action,'scheduling') && isfield(action.scheduling,'weightUE')
                w = action.scheduling.weightUE;
                if isnumeric(w) && numel(w) == numUE
                    w = w(:);
                    w(w<0)=0; w(w>10)=10;
                    ctrl.weightUE = w;
                end
            end

            % beam.ueBeamId (slot-only)
            if isfield(action,'beam') && isfield(action.beam,'ueBeamId')
                b = action.beam.ueBeamId;
                if isnumeric(b) && numel(b) == numUE
                    b = round(b(:));
                    b(b<0)=0;
                    ctrl.ueBeamId = b;
                end
            end

            % handover offsets (persistent)
            if isfield(action,'handover')
                if isfield(action.handover,'hysteresisOffset_dB')
                    v = action.handover.hysteresisOffset_dB;
                    if isnumeric(v) && numel(v) == numCell
                        ctrl.hysteresisOffset_dB = min(max(v(:),-5),5);
                    end
                end
                if isfield(action.handover,'tttOffset_slot')
                    v = action.handover.tttOffset_slot;
                    if isnumeric(v) && numel(v) == numCell
                        ctrl.tttOffset_slot = min(max(round(v(:)),-5),10);
                    end
                end
            end

            % rlf offset (persistent)
            if isfield(action,'rlf') && isfield(action.rlf,'sinrThresholdOffset_dB')
                v = action.rlf.sinrThresholdOffset_dB;
                if isnumeric(v)
                    ctrl.rlfSinrThresholdOffset_dB = min(max(v,-5),5);
                end
            end
        end

        function ctx = writeDebugTrace(obj, ctx, hasAction)

            % tmp exists by design; nextSlot clears it
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
            t.hasAction = hasAction;

            % ctrl summary
            t.ctrl = struct();
            t.ctrl.bandwidthScale_mean     = mean(ctx.ctrl.bandwidthScale);
            t.ctrl.txPowerOffset_mean_dB   = mean(ctx.ctrl.txPowerOffset_dB);
            t.ctrl.basePowerScale_mean     = mean(ctx.ctrl.basePowerScale);
            t.ctrl.sleepState              = ctx.ctrl.cellSleepState(:).';

            % runtime knobs
            t.runtime = struct();
            t.runtime.txPower_dBm          = ctx.txPowerCell_dBm(:).';
            t.runtime.numPRBPerCell        = ctx.numPRBPerCell(:).';
            t.runtime.bandwidthHzPerCell   = ctx.bandwidthHzPerCell(:).';

            ctx.tmp.debug.trace.(obj.moduleName) = t;
        end

        function tf = shouldPrint(obj, ctx)
            tf = false;

            if ~isfield(ctx.cfg,'debug'), return; end
            if ~isfield(ctx.cfg.debug,'enable'), return; end
            if ~ctx.cfg.debug.enable, return; end

            every = 1;
            if isfield(ctx.cfg.debug,'every') && isnumeric(ctx.cfg.debug.every) && ctx.cfg.debug.every >= 1
                every = round(ctx.cfg.debug.every);
            end
            if mod(ctx.slot, every) ~= 0
                return;
            end

            if isfield(ctx.cfg.debug,'modules')
                m = ctx.cfg.debug.modules;
                try
                    mm = string(m);
                    if ~(any(mm == "all") || any(mm == obj.moduleName))
                        return;
                    end
                catch
                end
            end

            tf = true;
        end

        function printDebug(obj, ctx)

            lvl = 1;
            if isfield(ctx.cfg.debug,'level') && isnumeric(ctx.cfg.debug.level)
                lvl = round(ctx.cfg.debug.level);
            end

            fprintf('[DEBUG][slot=%d][%s] ', ctx.slot, obj.moduleName);

            % hasAction from tmp trace
            hasA = false;
            if isfield(ctx.tmp,'debug') && isfield(ctx.tmp.debug,'trace') && ...
               isfield(ctx.tmp.debug.trace,obj.moduleName) && ...
               isfield(ctx.tmp.debug.trace.(obj.moduleName),'hasAction')
                hasA = ctx.tmp.debug.trace.(obj.moduleName).hasAction;
            end
            fprintf('hasAction=%d\n', hasA);

            fprintf('  ctrl: bwScaleMean=%.2f txOffMean=%.2f dB basePwrMean=%.2f sleep=%s\n', ...
                mean(ctx.ctrl.bandwidthScale), mean(ctx.ctrl.txPowerOffset_dB), ...
                mean(ctx.ctrl.basePowerScale), mat2str(ctx.ctrl.cellSleepState(:).'));

            if lvl >= 2
                fprintf('  runtime: txPower_dBm=%s\n', mat2str(ctx.txPowerCell_dBm(:).'));
                fprintf('  runtime: numPRBPerCell=%s\n', mat2str(ctx.numPRBPerCell(:).'));
            end

            if lvl >= 3
                fprintf('  runtime: bandwidthHzPerCell=%s\n', mat2str(ctx.bandwidthHzPerCell(:).'));
                fprintf('  ctrl(slotOnly): selectedUE=%s\n', mat2str(ctx.ctrl.selectedUE(:).'));
            end
        end
    end
end
