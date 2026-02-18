classdef RanContext
%RANCONTEXT Runtime state container for modular NR kernel
%
% v4.0 (baseline lifetime fix + per-cell radio knobs)
%
% Core idea:
%   - Persistent "baseline" is stored in obj.baseline (NOT in obj.tmp).
%   - obj.tmp is per-slot scratch and is cleared every slot in nextSlot().
%   - ActionApplier should reset controllables from obj.baseline each slot,
%     then apply action offsets.
%
% What this fixes:
%   - Prevents txPower/bandwidth/PRB drifting across slots due to tmp reset.
%   - Avoids scalar/vector mismatch by defining both scalar legacy and per-cell vectors.
%
% Reads/Writes:
%   - Kernel models read/write fields in this context.
%   - updateStateBus() publishes a read-only snapshot (obj.state) for RIC/xApps.

    properties
        %% =========================================================
        % Static
        %% =========================================================
        cfg
        scenario

        %% =========================================================
        % Baseline (PERSISTENT, never cleared by nextSlot)
        % ==========================================================
        % baseline.* fields are "factory defaults" for controllables:
        %   baseline.txPowerCell_dBm      [numCell x 1]
        %   baseline.numPRB              scalar
        %   baseline.numPRBPerCell       [numCell x 1]
        %   baseline.bandwidthHz         scalar
        %   baseline.bandwidthHzPerCell  [numCell x 1]
        %
        % Rule:
        %   - Never modify obj.baseline inside runtime loop.
        baseline

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
        txPowerCell_dBm   % runtime cell Tx power [numCell x 1] or scalar in old code

        % New per-cell knobs (preferred)
        numPRBPerCell         % [numCell x 1]
        bandwidthHzPerCell    % [numCell x 1]

        noiseFigure_dB
        thermalNoise_dBm

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
        % Action bus
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
            % Radio (baseline from ScenarioBuilder + derived)
            %% -------------------------------
            obj.bandwidthHz = scenario.radio.bandwidth;
            obj.scs         = scenario.radio.scs;

            % You currently fix PRB = 106 for 20MHz@30kHz (approx).
            % Keep as your baseline PRB. Later you may derive it from BW/SCS.
            obj.numPRB = 106;

            % IMPORTANT: keep txPower as per-cell vector in runtime
            baseTx = scenario.radio.txPower.cell;
            if isscalar(baseTx)
                obj.txPowerCell_dBm = baseTx * ones(numCell,1);
            else
                obj.txPowerCell_dBm = baseTx(:);
                if numel(obj.txPowerCell_dBm) ~= numCell
                    obj.txPowerCell_dBm = baseTx(1) * ones(numCell,1);
                end
            end

            % Per-cell runtime knobs (start from scalar baselines)
            obj.numPRBPerCell      = obj.numPRB      * ones(numCell,1);
            obj.bandwidthHzPerCell = obj.bandwidthHz * ones(numCell,1);

            % Thermal noise reference (legacy scalar BW)
            obj.noiseFigure_dB    = 7;
            obj.thermalNoise_dBm  = -174 + 10*log10(obj.bandwidthHz) + obj.noiseFigure_dB;

            %% -------------------------------
            % Baseline (PERSISTENT)
            %% -------------------------------
            obj.baseline = struct();
            obj.baseline.txPowerCell_dBm     = obj.txPowerCell_dBm(:);
            obj.baseline.numPRB              = obj.numPRB;
            obj.baseline.numPRBPerCell       = obj.numPRBPerCell(:);
            obj.baseline.bandwidthHz         = obj.bandwidthHz;
            obj.baseline.bandwidthHzPerCell  = obj.bandwidthHzPerCell(:);

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

            obj.accEnergyJPerCell     = zeros(numCell,1);
            obj.accEnergySignal_J_total = 0;

            obj.accHOCount            = 0;
            obj.accPingPongCount      = 0;
            obj.accRLFCount           = 0;

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
            obj.lastNumPRB                    = obj.numPRB;
            obj.lastScheduledUECountPerCell   = zeros(numCell,1);
            obj.lastPRBUsedPerCell_slot       = zeros(numCell,1);

            %% -------------------------------
            % action/tmp/state
            %% -------------------------------
            obj.action = [];
            obj.tmp    = struct();

            obj.state  = RanStateBus.init(cfg);
            obj = obj.updateStateBus();
        end

        function obj = nextSlot(obj)
            % Advance time and clear per-slot scratch

            obj.slot = obj.slot + 1;

            % tmp is per-slot only. Clearing it is correct.
            obj.tmp  = struct();

            % Episode slot count
            obj.accSlotCount = obj.accSlotCount + 1;

            % Reset per-slot observability containers
            obj.lastScheduledUECountPerCell(:) = 0;
            obj.lastPRBUsedPerCell_slot(:)     = 0;

            % NOTE:
            %   Do NOT reset baseline or runtime radio knobs here.
            %   ActionApplier is responsible for per-slot reset from obj.baseline.
        end

        function obj = setAction(obj, action)
            obj.action = action;
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

            % Ensure fields exist
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

            % Traffic observability (optional)
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

            % Publish runtime effective values (preferred per-cell)
            % txPower: always publish vector
            if isscalar(obj.txPowerCell_dBm)
                s.cell.txPower_dBm = obj.txPowerCell_dBm * ones(numCell,1);
            else
                s.cell.txPower_dBm = obj.txPowerCell_dBm(:);
            end

            % bandwidth/PRB: publish legacy scalar, but you can extend to per-cell later
            s.cell.bandwidthHz = obj.bandwidthHz * ones(numCell,1);
            s.cell.scs         = obj.scs * ones(numCell,1);
            s.cell.numPRB      = obj.numPRB * ones(numCell,1);

            s.cell.prbTotal = obj.numPRB * ones(numCell,1);

            % PRB used: prefer PHY tmp.lastPRBUsedPerCell, else use last slot cache
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

            % Sleep (kernel can later populate this from tmp/action)
            if ~isfield(s.cell,'sleepState') || numel(s.cell.sleepState) ~= numCell
                s.cell.sleepState = zeros(numCell,1);
            end

            % Energy
            s.cell.energy_J = obj.accEnergyJPerCell(:);

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

            obj.state = s;
        end
    end
end
