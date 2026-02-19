classdef RanContext
% RANCONTEXT v5 (Unified ctrl architecture + stable state bus + debug-ready)
%
% Core principles:
%   baseline  -> 永久不变
%   ctrl      -> ActionApplier 写入，跨 slot 持久
%   tmp       -> 每 slot 清空
%   action    -> 仅记录输入，不允许模型读取
%
% 所有模型必须只读:
%   ctx.ctrl
%   ctx.runtime knobs
%
% NEVER:
%   - 模型直接读取 ctx.action
%   - ctrl 放进 tmp
%

    properties

        %% =========================================================
        % Static
        %% =========================================================
        cfg
        scenario

        %% =========================================================
        % Baseline (PERSISTENT)
        %% =========================================================
        baseline

        %% =========================================================
        % Control (PERSISTENT, Action decoded)
        %% =========================================================
        ctrl

        %% =========================================================
        % Time
        %% =========================================================
        slot
        dt

        %% =========================================================
        % UE / Cell state
        %% =========================================================
        uePos
        servingCell

        rsrp_dBm
        measRsrp_dBm
        sinr_dB

        %% =========================================================
        % Runtime radio knobs
        %% =========================================================
        bandwidthHz
        scs
        numPRB

        numPRBPerCell
        bandwidthHzPerCell
        txPowerCell_dBm

        noiseFigure_dB
        thermalNoise_dBm
        thermalNoiseCell_dBm

        %% =========================================================
        % HO state
        %% =========================================================
        hoTimer
        ueBlockedUntilSlot
        uePostHoUntilSlot
        uePostHoSinrPenalty_dB
        lastHoFromCell
        lastHoSlot

        %% =========================================================
        % RLF state
        %% =========================================================
        ueInOutageUntilSlot
        lastRlfFromCell
        lastRlfSlot
        rlfTimer

        %% =========================================================
        % Scheduler
        %% =========================================================
        rrPtr

        %% =========================================================
        % Accumulators
        %% =========================================================
        accThroughputBitPerUE
        accDroppedTotal
        accDroppedURLLC

        accPRBUsedPerCell
        accPRBTotalPerCell

        accEnergyJPerCell
        accEnergySignal_J_total

        accHOCount
        accPingPongCount
        accRLFCount

        accSlotCount

        accSinrSum_dB
        accSinrCount

        accMcsSum
        accMcsCount

        accBlerSum
        accBlerCount

        accScheduledUeSumPerCell
        accScheduledUeCountPerCell

        %% =========================================================
        % Per-slot observability
        %% =========================================================
        lastNumPRB
        lastScheduledUECountPerCell
        lastPRBUsedPerCell_slot

        %% =========================================================
        % Action input (record only)
        %% =========================================================
        action

        %% =========================================================
        % Per-slot scratch
        %% =========================================================
        tmp

        %% =========================================================
        % Published state
        %% =========================================================
        state

        %% =========================================================
        % Debug
        %% =========================================================
        debugEnable logical = false
        debugFirstSlots double = 3

    end

    %% =====================================================================
    % Constructor
    %% =====================================================================
    methods
        function obj = RanContext(cfg, scenario)

            obj.cfg      = cfg;
            obj.scenario = scenario;

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            %% Time
            obj.slot = 0;
            obj.dt   = cfg.sim.slotDuration;

            %% UE init
            obj.uePos       = scenario.topology.ueInitPos;
            obj.servingCell = ones(numUE,1);

            obj.rsrp_dBm     = zeros(numUE,numCell);
            obj.measRsrp_dBm = zeros(numUE,numCell);
            obj.sinr_dB      = zeros(numUE,1);

            %% Radio baseline
            obj.bandwidthHz = scenario.radio.bandwidth;
            obj.scs         = scenario.radio.scs;
            obj.numPRB      = 106;

            baseTx = scenario.radio.txPower.cell;
            if isscalar(baseTx)
                obj.txPowerCell_dBm = baseTx * ones(numCell,1);
            else
                obj.txPowerCell_dBm = baseTx(:);
            end

            obj.numPRBPerCell      = obj.numPRB      * ones(numCell,1);
            obj.bandwidthHzPerCell = obj.bandwidthHz * ones(numCell,1);

            obj.noiseFigure_dB = 7;
            obj = obj.refreshNoise();

            %% Baseline
            obj.baseline.txPowerCell_dBm    = obj.txPowerCell_dBm;
            obj.baseline.numPRB             = obj.numPRB;
            obj.baseline.numPRBPerCell      = obj.numPRBPerCell;
            obj.baseline.bandwidthHz        = obj.bandwidthHz;
            obj.baseline.bandwidthHzPerCell = obj.bandwidthHzPerCell;
            obj.baseline.noiseFigure_dB     = obj.noiseFigure_dB;

            %% ctrl (完整字段初始化)
            obj.ctrl.basePowerScale = ones(numCell,1);
            obj.ctrl.cellSleepState = zeros(numCell,1);
            obj.ctrl.selectedUE     = zeros(numCell,1);
            obj.ctrl.bandwidthScale = ones(numCell,1);
            obj.ctrl.txPowerOffset_dB = zeros(numCell,1);

            obj.ctrl.ueBeamId = zeros(numUE,1);
            obj.ctrl.beamMode = "static";

            %% HO / RLF
            obj.hoTimer                = zeros(numUE,1);
            obj.ueBlockedUntilSlot     = zeros(numUE,1);
            obj.uePostHoUntilSlot      = zeros(numUE,1);
            obj.uePostHoSinrPenalty_dB = zeros(numUE,1);
            obj.lastHoFromCell         = zeros(numUE,1);
            obj.lastHoSlot             = -inf(numUE,1);

            obj.ueInOutageUntilSlot = zeros(numUE,1);
            obj.lastRlfFromCell     = zeros(numUE,1);
            obj.lastRlfSlot         = -inf(numUE,1);
            obj.rlfTimer            = zeros(numUE,1);

            %% Scheduler
            obj.rrPtr = ones(numCell,1);

            %% Accumulators
            obj.accThroughputBitPerUE = zeros(numUE,1);
            obj.accDroppedTotal       = 0;
            obj.accDroppedURLLC       = 0;

            obj.accPRBUsedPerCell  = zeros(numCell,1);
            obj.accPRBTotalPerCell = zeros(numCell,1);

            obj.accEnergyJPerCell = zeros(numCell,1);

            obj.accHOCount       = 0;
            obj.accPingPongCount = 0;
            obj.accRLFCount      = 0;

            obj.accSlotCount = 0;

            obj.accSinrSum_dB = 0;
            obj.accSinrCount  = 0;

            obj.accMcsSum   = 0;
            obj.accMcsCount = 0;

            obj.accBlerSum   = 0;
            obj.accBlerCount = 0;

            obj.accScheduledUeSumPerCell   = zeros(numCell,1);
            obj.accScheduledUeCountPerCell = zeros(numCell,1);

            %% Observability
            obj.lastNumPRB                  = obj.numPRB;
            obj.lastScheduledUECountPerCell = zeros(numCell,1);
            obj.lastPRBUsedPerCell_slot     = zeros(numCell,1);

            %% action/tmp/state
            obj.action = [];
            obj.tmp    = struct();

            obj.state  = RanStateBus.init(cfg);
            obj = obj.updateStateBus();

            %% Debg

            obj.debugEnable    = false;
            obj.debugFirstSlots = 3;

        end
    end

    %% =====================================================================
    % Slot advance
    %% =====================================================================
    methods
        function obj = nextSlot(obj)
            obj.slot = obj.slot + 1;
            obj.tmp  = struct();
            obj.accSlotCount = obj.accSlotCount + 1;

            obj.lastScheduledUECountPerCell(:) = 0;
            obj.lastPRBUsedPerCell_slot(:)     = 0;
        end
    end

    %% =====================================================================
    % Noise refresh
    %% =====================================================================
    methods
        function obj = refreshNoise(obj)

            numCell = obj.cfg.scenario.numCell;

            obj.thermalNoise_dBm = ...
                -174 + 10*log10(max(obj.bandwidthHz,1)) + obj.noiseFigure_dB;

            bw = obj.bandwidthHzPerCell(:);
            bw(bw<=1) = 1;

            if numel(bw) ~= numCell
                bw = obj.bandwidthHz * ones(numCell,1);
            end

            obj.thermalNoiseCell_dBm = ...
                -174 + 10*log10(bw) + obj.noiseFigure_dB;
        end
    end

    %% =====================================================================
    % Debug
    %% =====================================================================
    methods
        function obj = setDebug(obj, enable, firstSlots)
            if nargin<2, enable=true; end
            if nargin<3, firstSlots=3; end
            obj.debugEnable = enable;
            obj.debugFirstSlots = firstSlots;
        end
    end

    %% =====================================================================
    % State sync
    %% =====================================================================
    methods
        function obj = updateStateBus(obj)

            numUE   = obj.cfg.scenario.numUE;
            numCell = obj.cfg.scenario.numCell;

            s = obj.state;

            s.time.slot = obj.slot;
            s.time.t_s  = obj.slot * obj.dt;

            s.ue.pos         = obj.uePos;
            s.ue.servingCell = obj.servingCell;
            s.ue.sinr_dB     = obj.sinr_dB;
            s.ue.rsrp_dBm    = obj.rsrp_dBm;
            s.ue.measRsrp_dBm= obj.measRsrp_dBm;

            s.ue.inOutage = obj.ueInOutageUntilSlot > obj.slot;

            s.cell.txPower_dBm = obj.txPowerCell_dBm;
            s.cell.bandwidthHz = obj.bandwidthHzPerCell;
            s.cell.numPRB      = obj.numPRBPerCell;

            prbUsed = zeros(numCell,1);
            if isfield(obj.tmp,'lastPRBUsedPerCell')
                prbUsed = obj.tmp.lastPRBUsedPerCell;
            end

            s.cell.prbTotal = obj.numPRBPerCell;
            s.cell.prbUsed  = prbUsed;
            s.cell.prbUtil  = min(max(prbUsed ./ max(obj.numPRBPerCell,1),0),1);

            s.cell.sleepState = obj.ctrl.cellSleepState;
            s.cell.energy_J   = obj.accEnergyJPerCell;

            s.kpi.throughputBitPerUE = obj.accThroughputBitPerUE;
            s.kpi.dropTotal          = obj.accDroppedTotal;
            s.kpi.dropURLLC          = obj.accDroppedURLLC;
            s.kpi.handoverCount      = obj.accHOCount;
            s.kpi.rlfCount           = obj.accRLFCount;

            s.ctrl = obj.ctrl;

            obj.state = s;

            if logical(obj.debugEnable) && obj.slot <= obj.debugFirstSlots
                %disp("RanContext slot=" + obj.slot);
            end
        end
    end
end
