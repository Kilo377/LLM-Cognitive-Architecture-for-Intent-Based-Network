classdef RanContext
%RANCONTEXT Runtime state container for modular NR kernel
%
% v4.1 (Most complete, stable baseline + persistent ctrl + per-cell knobs)
%
% Design goals
% 1) baseline is persistent and never cleared.
% 2) ctrl is persistent "decoded action state" that can be consumed by models.
% 3) tmp is per-slot scratch and is cleared every slot.
% 4) per-cell runtime knobs exist and are published to state bus.
% 5) scalar legacy knobs are kept for old modules, but must be consistent.
%
% Key rules
% - NEVER store baseline inside tmp.
% - NEVER store action-decoded control state inside tmp.
% - Use ctrl.* for action-derived values that must persist and be readable by models.
%
% Typical lifecycle per slot
%   nextSlot(): clear tmp, advance time
%   ActionApplier.step(): reset runtime knobs from baseline; apply action; write ctrl
%   PHY/Scheduler/HO/Energy/KPI models: read runtime knobs + ctrl; write tmp + accumulators
%   updateStateBus(): publish read-only snapshot (state) for RIC/xApps

    properties
        %% =========================================================
        % Static configuration and scenario
        %% =========================================================
        cfg
        scenario

        %% =========================================================
        % Baseline (PERSISTENT, never cleared)
        %% =========================================================
        baseline
        % baseline fields:
        %   txPowerCell_dBm      [numCell x 1]
        %   numPRB               scalar
        %   numPRBPerCell        [numCell x 1]
        %   bandwidthHz          scalar
        %   bandwidthHzPerCell   [numCell x 1]
        %   noiseFigure_dB       scalar

        %% =========================================================
        % Control state (PERSISTENT, decoded from action)
        %% =========================================================
        ctrl
        % ctrl fields (recommend):
        %   basePowerScale       [numCell x 1]  (energy-only scale)
        %   cellSleepState       [numCell x 1]  (0/1/2)
        %   cellIsSleeping       [numCell x 1]  (0/1)
        %   selectedUE           [numCell x 1]  (scheduler hint)

        %% =========================================================
        % Time
        %% =========================================================
        slot
        dt

        %% =========================================================
        % UE / Cell core state
        %% =========================================================
        uePos
        servingCell

        rsrp_dBm
        measRsrp_dBm
        sinr_dB

        %% =========================================================
        % Radio parameters (RUNTIME)
        %% =========================================================
        % Legacy scalar knobs (for modules that assume scalar)
        bandwidthHz
        scs
        numPRB

        % Runtime per-cell knobs (preferred)
        numPRBPerCell
        bandwidthHzPerCell
        txPowerCell_dBm              % runtime per-cell vector (preferred)

        % Noise
        noiseFigure_dB               % scalar NF
        thermalNoise_dBm             % legacy scalar thermal noise based on bandwidthHz
        thermalNoiseCell_dBm         % per-cell thermal noise based on bandwidthHzPerCell

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
        % Scheduler state
        %% =========================================================
        rrPtr

        %% =========================================================
        % Traffic / throughput accumulators
        %% =========================================================
        accThroughputBitPerUE
        accDroppedTotal
        accDroppedURLLC

        %% =========================================================
        % PRB accumulators (episode)
        %% =========================================================
        accPRBUsedPerCell
        accPRBTotalPerCell

        %% =========================================================
        % Energy accumulators
        %% =========================================================
        accEnergyJPerCell
        accEnergySignal_J_total

        %% =========================================================
        % HO / RLF accumulators
        %% =========================================================
        accHOCount
        accPingPongCount
        accRLFCount

        %% =========================================================
        % KPI accumulators (episode)
        %% =========================================================
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
        % Per-slot observability (runtime helpers)
        %% =========================================================
        lastNumPRB
        lastScheduledUECountPerCell
        lastPRBUsedPerCell_slot

        %% =========================================================
        % Action bus (raw input for current slot)
        %% =========================================================
        action

        %% =========================================================
        % Temporary per-slot scratch (CLEARED every slot)
        %% =========================================================
        tmp

        %% =========================================================
        % Published state bus (read-only for xApps)
        %% =========================================================
        state
    end

    methods
        function obj = RanContext(cfg, scenario)

            obj.cfg      = cfg;
            obj.scenario = scenario;

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            %% -------------------------------
            % Time
            %% -------------------------------
            obj.slot = 0;
            obj.dt   = cfg.sim.slotDuration;

            %% -------------------------------
            % UE/Cell core
            %% -------------------------------
            obj.uePos       = scenario.topology.ueInitPos;
            obj.servingCell = ones(numUE,1);

            obj.rsrp_dBm     = zeros(numUE,numCell);
            obj.measRsrp_dBm = zeros(numUE,numCell);
            obj.sinr_dB      = zeros(numUE,1);

            %% -------------------------------
            % Radio baselines from scenario
            %% -------------------------------
            obj.bandwidthHz = scenario.radio.bandwidth;
            obj.scs         = scenario.radio.scs;

            % Keep your current PRB baseline (later can derive from BW/SCS)
            obj.numPRB = 106;

            % Tx power: force per-cell vector
            baseTx = scenario.radio.txPower.cell;
            if isscalar(baseTx)
                obj.txPowerCell_dBm = baseTx * ones(numCell,1);
            else
                obj.txPowerCell_dBm = baseTx(:);
                if numel(obj.txPowerCell_dBm) ~= numCell
                    obj.txPowerCell_dBm = baseTx(1) * ones(numCell,1);
                end
            end

            % Per-cell runtime knobs start from scalar baseline
            obj.numPRBPerCell      = obj.numPRB      * ones(numCell,1);
            obj.bandwidthHzPerCell = obj.bandwidthHz * ones(numCell,1);

            % Noise
            obj.noiseFigure_dB = 7;

            % Legacy scalar thermal noise uses scalar bandwidthHz
            obj.thermalNoise_dBm = -174 + 10*log10(obj.bandwidthHz) + obj.noiseFigure_dB;

            % Per-cell thermal noise uses bandwidthHzPerCell
            obj.thermalNoiseCell_dBm = -174 + 10*log10(obj.bandwidthHzPerCell) + obj.noiseFigure_dB;

            %% -------------------------------
            % Baseline (PERSISTENT)
            %% -------------------------------
            obj.baseline = struct();
            obj.baseline.txPowerCell_dBm     = obj.txPowerCell_dBm(:);
            obj.baseline.numPRB              = obj.numPRB;
            obj.baseline.numPRBPerCell       = obj.numPRBPerCell(:);
            obj.baseline.bandwidthHz         = obj.bandwidthHz;
            obj.baseline.bandwidthHzPerCell  = obj.bandwidthHzPerCell(:);
            obj.baseline.noiseFigure_dB      = obj.noiseFigure_dB;

            %% -------------------------------
            % Control state (PERSISTENT)
            %% -------------------------------
            obj.ctrl = struct();
            obj.ctrl.basePowerScale = ones(numCell,1);
            obj.ctrl.cellSleepState = zeros(numCell,1);
            obj.ctrl.cellIsSleeping = zeros(numCell,1);
            obj.ctrl.selectedUE     = zeros(numCell,1);

            %% -------------------------------
            % HO state
            %% -------------------------------
            obj.hoTimer                = zeros(numUE,1);
            obj.ueBlockedUntilSlot     = zeros(numUE,1);
            obj.uePostHoUntilSlot      = zeros(numUE,1);
            obj.uePostHoSinrPenalty_dB = zeros(numUE,1);
            obj.lastHoFromCell         = zeros(numUE,1);
            obj.lastHoSlot             = -inf(numUE,1);

            %% -------------------------------
            % RLF state
            %% -------------------------------
            obj.ueInOutageUntilSlot = zeros(numUE,1);
            obj.lastRlfFromCell     = zeros(numUE,1);
            obj.lastRlfSlot         = -inf(numUE,1);
            obj.rlfTimer            = zeros(numUE,1);

            %% -------------------------------
            % Scheduler
            %% -------------------------------
            obj.rrPtr = ones(numCell,1);

            %% -------------------------------
            % Accumulators
            %% -------------------------------
            obj.accThroughputBitPerUE = zeros(numUE,1);
            obj.accDroppedTotal       = 0;
            obj.accDroppedURLLC       = 0;

            obj.accPRBUsedPerCell     = zeros(numCell,1);
            obj.accPRBTotalPerCell    = zeros(numCell,1);

            obj.accEnergyJPerCell       = zeros(numCell,1);
            obj.accEnergySignal_J_total = 0;

            obj.accHOCount       = 0;
            obj.accPingPongCount = 0;
            obj.accRLFCount      = 0;

            %% -------------------------------
            % KPI episode accumulators
            %% -------------------------------
            obj.accSlotCount = 0;

            obj.accSinrSum_dB = 0;
            obj.accSinrCount  = 0;

            obj.accMcsSum   = 0;
            obj.accMcsCount = 0;

            obj.accBlerSum   = 0;
            obj.accBlerCount = 0;

            obj.accScheduledUeSumPerCell   = zeros(numCell,1);
            obj.accScheduledUeCountPerCell = zeros(numCell,1);

            %% -------------------------------
            % Per-slot observability
            %% -------------------------------
            obj.lastNumPRB                  = obj.numPRB;
            obj.lastScheduledUECountPerCell = zeros(numCell,1);
            obj.lastPRBUsedPerCell_slot     = zeros(numCell,1);

            %% -------------------------------
            % action/tmp/state
            %% -------------------------------
            obj.action = [];
            obj.tmp    = struct();

            obj.state  = RanStateBus.init(cfg);
            obj = obj.updateStateBus();

            %% -------------------------------
            % Safety guards (fail-fast)
            %% -------------------------------
            obj = obj.assertShapeConsistency();
        end

        function obj = nextSlot(obj)
            % Advance time and clear per-slot scratch.
            % Do not touch baseline or ctrl here.

            obj.slot = obj.slot + 1;
            obj.tmp  = struct();

            obj.accSlotCount = obj.accSlotCount + 1;

            % Reset per-slot observability containers
            obj.lastScheduledUECountPerCell(:) = 0;
            obj.lastPRBUsedPerCell_slot(:)     = 0;
        end

        function obj = setAction(obj, action)
            obj.action = action;
        end

        function obj = refreshNoise(obj)
            % Refresh noise based on current runtime bandwidth knobs.
            % Call this after bandwidthHzPerCell changes.

            numCell = obj.cfg.scenario.numCell;

            % Legacy scalar uses scalar bandwidthHz
            obj.thermalNoise_dBm = -174 + 10*log10(max(obj.bandwidthHz,1)) + obj.noiseFigure_dB;

            % Per-cell uses bandwidthHzPerCell
            bw = obj.bandwidthHzPerCell(:);
            if numel(bw) ~= numCell
                bw = obj.bandwidthHz * ones(numCell,1);
            end
            bw(bw <= 1) = 1;

            obj.thermalNoiseCell_dBm = -174 + 10*log10(bw) + obj.noiseFigure_dB;
        end

        function obj = assertShapeConsistency(obj)
            % Fail-fast checks for scalar/vector mismatch.

            numCell = obj.cfg.scenario.numCell;

            if isscalar(obj.txPowerCell_dBm)
                error("RanContext:txPowerCell_dBm must be vector [numCell x 1].");
            end
            if numel(obj.txPowerCell_dBm) ~= numCell
                error("RanContext:txPowerCell_dBm size mismatch.");
            end
            if numel(obj.numPRBPerCell) ~= numCell
                error("RanContext:numPRBPerCell size mismatch.");
            end
            if numel(obj.bandwidthHzPerCell) ~= numCell
                error("RanContext:bandwidthHzPerCell size mismatch.");
            end
            if numel(obj.ctrl.basePowerScale) ~= numCell
                error("RanContext:ctrl.basePowerScale size mismatch.");
            end
            if numel(obj.ctrl.cellSleepState) ~= numCell
                error("RanContext:ctrl.cellSleepState size mismatch.");
            end
            if numel(obj.ctrl.selectedUE) ~= numCell
                error("RanContext:ctrl.selectedUE size mismatch.");
            end
        end

        %% =========================================================
        % Accumulator helpers
        %% =========================================================
        function obj = accSinr(obj, sinrVec_dB)
            v = sinrVec_dB(:);
            v = v(isfinite(v));
            if isempty(v), return; end
            obj.accSinrSum_dB = obj.accSinrSum_dB + sum(v);
            obj.accSinrCount  = obj.accSinrCount  + numel(v);
        end

        function obj = accMcs(obj, mcsVec)
            v = mcsVec(:);
            v = v(isfinite(v));
            if isempty(v), return; end
            obj.accMcsSum   = obj.accMcsSum   + sum(v);
            obj.accMcsCount = obj.accMcsCount + numel(v);
        end

        function obj = accBler(obj, blerVec)
            v = blerVec(:);
            v = v(isfinite(v));
            if isempty(v), return; end
            obj.accBlerSum   = obj.accBlerSum   + sum(v);
            obj.accBlerCount = obj.accBlerCount + numel(v);
        end

        function obj = accScheduledPerCell(obj, schedCntPerCell)
            x = schedCntPerCell(:);
            if numel(x) ~= numel(obj.accScheduledUeSumPerCell), return; end
            obj.accScheduledUeSumPerCell    = obj.accScheduledUeSumPerCell + x;
            obj.accScheduledUeCountPerCell  = obj.accScheduledUeCountPerCell + 1;
            obj.lastScheduledUECountPerCell = x;
        end

        function obj = accPrbUsedSlot(obj, prbUsedPerCell)
            x = prbUsedPerCell(:);
            if numel(x) ~= numel(obj.lastPRBUsedPerCell_slot), return; end
            obj.lastPRBUsedPerCell_slot = x;
        end

        %% =========================================================
        % Sync to state bus
        %% =========================================================
        function obj = updateStateBus(obj)

            cfg = obj.cfg;
            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            s = obj.state;

            %% -------------------------------
            % time
            %% -------------------------------
            s.time.slot = obj.slot;
            s.time.t_s  = double(obj.slot) * double(obj.dt);

            %% -------------------------------
            % topology
            %% -------------------------------
            s.topology.numUE   = numUE;
            s.topology.numCell = numCell;

            if isfield(obj.scenario,'topology') && isfield(obj.scenario.topology,'gNBPos')
                s.topology.gNBPos = obj.scenario.topology.gNBPos;
            elseif isfield(obj.scenario,'topology') && isfield(obj.scenario.topology,'gNBPos_m')
                s.topology.gNBPos = obj.scenario.topology.gNBPos_m;
            end

            %% -------------------------------
            % UE
            %% -------------------------------
            s.ue.pos         = obj.uePos;
            s.ue.servingCell = obj.servingCell;

            s.ue.sinr_dB      = obj.sinr_dB;
            s.ue.rsrp_dBm     = obj.rsrp_dBm;
            s.ue.measRsrp_dBm = obj.measRsrp_dBm;

            if ~isfield(s.ue,'cqi');  s.ue.cqi  = zeros(numUE,1); end
            if ~isfield(s.ue,'mcs');  s.ue.mcs  = zeros(numUE,1); end
            if ~isfield(s.ue,'bler'); s.ue.bler = zeros(numUE,1); end

            % Sync PHY feedback from tmp if present
            if isfield(obj.tmp,'lastCQIPerUE')
                v = obj.tmp.lastCQIPerUE(:);
                if numel(v) == numUE, s.ue.cqi = v; end
            end
            if isfield(obj.tmp,'lastMCSPerUE')
                v = obj.tmp.lastMCSPerUE(:);
                if numel(v) == numUE, s.ue.mcs = v; end
            end
            if isfield(obj.tmp,'lastBLERPerUE')
                v = obj.tmp.lastBLERPerUE(:);
                if numel(v) == numUE, s.ue.bler = v; end
            end

            % Optional traffic observability
            if isfield(obj.tmp,'ue')
                if isfield(obj.tmp.ue,'buffer_bits');      s.ue.buffer_bits      = obj.tmp.ue.buffer_bits; end
                if isfield(obj.tmp.ue,'urgent_pkts');      s.ue.urgent_pkts      = obj.tmp.ue.urgent_pkts; end
                if isfield(obj.tmp.ue,'minDeadline_slot'); s.ue.minDeadline_slot = obj.tmp.ue.minDeadline_slot; end
            end

            s.ue.inOutage = (obj.ueInOutageUntilSlot > obj.slot);

            %% -------------------------------
            % CELL
            %% -------------------------------
            if ~isfield(s,'cell'), s.cell = struct(); end

            % Tx power (per-cell)
            s.cell.txPower_dBm = obj.txPowerCell_dBm(:);

            % Publish per-cell runtime knobs
            s.cell.bandwidthHz = obj.bandwidthHzPerCell(:);
            s.cell.numPRB      = obj.numPRBPerCell(:);

            % Keep legacy scalars for backward compatibility
            s.cell.bandwidthHz_legacy = obj.bandwidthHz;
            s.cell.numPRB_legacy      = obj.numPRB;
            s.cell.scs                = obj.scs * ones(numCell,1);

            % PRB totals (per-cell)
            s.cell.prbTotal = obj.numPRBPerCell(:);

            % PRB used: prefer tmp.lastPRBUsedPerCell, else use last slot cache
            prbUsed = zeros(numCell,1);
            if isfield(obj.tmp,'lastPRBUsedPerCell')
                v = obj.tmp.lastPRBUsedPerCell(:);
                if numel(v) == numCell
                    prbUsed = v;
                end
            elseif any(obj.lastPRBUsedPerCell_slot > 0)
                prbUsed = obj.lastPRBUsedPerCell_slot(:);
            end
            s.cell.prbUsed = prbUsed;

            den = s.cell.prbTotal(:);
            den(den <= 0) = 1;
            util = s.cell.prbUsed(:) ./ den;
            util(util < 0) = 0;
            util(util > 1) = 1;
            s.cell.prbUtil = util;

            % Sleep state from ctrl (persistent)
            if ~isfield(s.cell,'sleepState') || numel(s.cell.sleepState) ~= numCell
                s.cell.sleepState = zeros(numCell,1);
            end
            if isfield(obj,'ctrl') && isfield(obj.ctrl,'cellSleepState')
                v = obj.ctrl.cellSleepState(:);
                if numel(v) == numCell
                    s.cell.sleepState = v;
                end
            end

            % Energy (accumulated)
            s.cell.energy_J = obj.accEnergyJPerCell(:);

            % Power (instant, if energy model wrote it)
            if ~isfield(s.cell,'power_W') || numel(s.cell.power_W) ~= numCell
                s.cell.power_W = zeros(numCell,1);
            end
            if isfield(obj.tmp,'energyWPerCell')
                v = obj.tmp.energyWPerCell(:);
                if numel(v) == numCell
                    s.cell.power_W = v;
                end
            end

            %% -------------------------------
            % EVENTS (episode counters)
            %% -------------------------------
            if ~isfield(s,'events'), s.events = struct(); end
            if ~isfield(s.events,'handover'), s.events.handover = struct(); end
            if ~isfield(s.events,'rlf'), s.events.rlf = struct(); end

            s.events.handover.countTotal    = obj.accHOCount;
            s.events.handover.pingPongCount = obj.accPingPongCount;
            s.events.rlf.countTotal         = obj.accRLFCount;

            %% -------------------------------
            % KPI (episode accumulators)
            %% -------------------------------
            if ~isfield(s,'kpi'), s.kpi = struct(); end

            s.kpi.throughputBitPerUE = obj.accThroughputBitPerUE(:);
            s.kpi.dropTotal          = obj.accDroppedTotal;
            s.kpi.dropURLLC          = obj.accDroppedURLLC;

            s.kpi.handoverCount = obj.accHOCount;
            s.kpi.rlfCount      = obj.accRLFCount;

            s.kpi.energyJPerCell       = obj.accEnergyJPerCell(:);
            s.kpi.energySignal_J_total = obj.accEnergySignal_J_total;

            s.kpi.prbUtilPerCell = s.cell.prbUtil(:);

            if obj.accSinrCount > 0
                s.kpi.meanSINR_dB = obj.accSinrSum_dB / obj.accSinrCount;
            else
                s.kpi.meanSINR_dB = 0;
            end

            if obj.accMcsCount > 0
                s.kpi.meanMCS = obj.accMcsSum / obj.accMcsCount;
            else
                s.kpi.meanMCS = 0;
            end

            if obj.accBlerCount > 0
                s.kpi.meanBLER = obj.accBlerSum / obj.accBlerCount;
            else
                s.kpi.meanBLER = 0;
            end

            denom2 = max(obj.accScheduledUeCountPerCell, 1);
            s.kpi.meanScheduledUEPerCell = obj.accScheduledUeSumPerCell ./ denom2;
            s.kpi.lastScheduledUECountPerCell = obj.lastScheduledUECountPerCell(:);

            %% -------------------------------
            % Control observability (optional but useful for debugging)
            %% -------------------------------
            if ~isfield(s,'ctrl'), s.ctrl = struct(); end
            s.ctrl.basePowerScale = obj.ctrl.basePowerScale(:);
            s.ctrl.selectedUE     = obj.ctrl.selectedUE(:);
            s.ctrl.cellSleepState = obj.ctrl.cellSleepState(:);

            obj.state = s;
        end
    end
end
