classdef RanContext
%RANCONTEXT Runtime state container for modular NR kernel
%
% v2:
% - Adds updateStateBus() to synchronize RanContext -> RanStateBus
% - Keeps kernel-internal timers private, exposes only observable events/KPIs via state bus

    properties
        %% ===== Static =====
        cfg
        scenario

        %% ===== Time =====
        slot
        dt

        %% ===== UE / Cell core state =====
        uePos
        servingCell

        rsrp_dBm
        measRsrp_dBm
        sinr_dB

        %% ===== Radio parameters =====
        bandwidthHz
        scs
        numPRB
        txPowerCell_dBm
        noiseFigure_dB
        thermalNoise_dBm

        %% ===== HO state =====
        hoTimer
        ueBlockedUntilSlot
        uePostHoUntilSlot
        uePostHoSinrPenalty_dB

        lastHoFromCell
        lastHoSlot

        %% ===== RLF state =====
        ueInOutageUntilSlot
        lastRlfFromCell
        lastRlfSlot
        rlfTimer

        %% ===== Scheduler state =====
        rrPtr

        %% ===== Traffic / throughput accumulators =====
        accThroughputBitPerUE
        accDroppedTotal
        accDroppedURLLC

        %% ===== PRB accumulators =====
        accPRBUsedPerCell
        accPRBTotalPerCell

        %% ===== Energy accumulators =====
        accEnergyJPerCell
        accEnergySignal_J_total

        %% ===== HO / RLF accumulators =====
        accHOCount
        accPingPongCount
        accRLFCount

        %% ===== Action bus =====
        action

        %% ===== Temporary per-slot scratch =====
        tmp

        %% ===== Published state bus (RIC reads) =====
        state
    end

    methods

        function obj = RanContext(cfg, scenario)

            obj.cfg      = cfg;
            obj.scenario = scenario;

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            %% ===== Time =====
            obj.slot = 0;
            obj.dt   = cfg.sim.slotDuration;

            %% ===== UE / Cell =====
            obj.uePos       = scenario.topology.ueInitPos;
            obj.servingCell = ones(numUE,1);

            obj.rsrp_dBm     = zeros(numUE,numCell);
            obj.measRsrp_dBm = zeros(numUE,numCell);
            obj.sinr_dB      = zeros(numUE,1);

            %% ===== Radio parameters =====
            obj.bandwidthHz = scenario.radio.bandwidth;
            obj.scs         = scenario.radio.scs;

            % PRB derivation (approx)
            obj.numPRB = 106; % can be derived later

            obj.txPowerCell_dBm = scenario.radio.txPower.cell;

            obj.noiseFigure_dB = 7;  % typical UE NF

            % Thermal noise calculation
            obj.thermalNoise_dBm = ...
                -174 + 10*log10(obj.bandwidthHz) + obj.noiseFigure_dB;

            %% ===== HO state =====
            obj.hoTimer                 = zeros(numUE,1);
            obj.ueBlockedUntilSlot      = zeros(numUE,1);
            obj.uePostHoUntilSlot       = zeros(numUE,1);
            obj.uePostHoSinrPenalty_dB  = zeros(numUE,1);

            obj.lastHoFromCell = zeros(numUE,1);
            obj.lastHoSlot     = -inf(numUE,1);

            %% ===== RLF state =====
            obj.ueInOutageUntilSlot = zeros(numUE,1);
            obj.lastRlfFromCell     = zeros(numUE,1);
            obj.lastRlfSlot         = -inf(numUE,1);
            obj.rlfTimer            = zeros(numUE,1);

            %% ===== Scheduler =====
            obj.rrPtr = ones(numCell,1);

            %% ===== KPI accumulators =====
            obj.accThroughputBitPerUE = zeros(numUE,1);

            obj.accDroppedTotal = 0;
            obj.accDroppedURLLC = 0;

            obj.accPRBUsedPerCell  = zeros(numCell,1);
            obj.accPRBTotalPerCell = zeros(numCell,1);

            obj.accEnergyJPerCell       = zeros(numCell,1);
            obj.accEnergySignal_J_total = 0;

            obj.accHOCount       = 0;
            obj.accPingPongCount = 0;
            obj.accRLFCount      = 0;

            %% ===== Action =====
            obj.action = [];

            %% ===== Temp =====
            obj.tmp = struct();

            %% ===== Published state bus =====
            obj.state = RanStateBus.init(cfg);

            % initial sync
            obj = obj.updateStateBus();
        end

        %% ===============================
        % Advance slot
        %% ===============================
        function obj = nextSlot(obj)
            obj.slot = obj.slot + 1;
            obj.tmp  = struct();
        end

        %% ===============================
        % Apply action
        %% ===============================
        function obj = setAction(obj, action)
            obj.action = action;
        end

        %% ===============================
        % Sync to state bus (Kernel -> RIC)
        %% ===============================
        function obj = updateStateBus(obj)
            % Update published state bus from internal context.
            %
            % Rule:
            % - Do not export kernel-internal timers directly.
            % - Export only observable signals, events, and KPIs.

            cfg = obj.cfg;
            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            s = obj.state;

            %% ---- time ----
            s.time.slot = obj.slot;
            s.time.t_s  = double(obj.slot) * double(obj.dt);

            %% ---- topology ----
            s.topology.numUE   = numUE;
            s.topology.numCell = numCell;

            if isfield(obj.scenario,'topology') && isfield(obj.scenario.topology,'gNBPos')
                s.topology.gNBPos = obj.scenario.topology.gNBPos;
            elseif isfield(obj.scenario,'topology') && isfield(obj.scenario.topology,'gNBPos_m')
                s.topology.gNBPos = obj.scenario.topology.gNBPos_m;
            else
                % keep default zeros if not available
            end

            %% ---- UE ----
            s.ue.pos         = obj.uePos;
            s.ue.servingCell = obj.servingCell;

            s.ue.sinr_dB      = obj.sinr_dB;
            s.ue.rsrp_dBm     = obj.rsrp_dBm;
            s.ue.measRsrp_dBm = obj.measRsrp_dBm;

            % optional PHY feedback if maintained elsewhere
            if ~isfield(s.ue,'cqi');  s.ue.cqi  = zeros(numUE,1); end
            if ~isfield(s.ue,'mcs');  s.ue.mcs  = zeros(numUE,1); end
            if ~isfield(s.ue,'bler'); s.ue.bler = zeros(numUE,1); end

            % Traffic observability: try to source from tmp if present
            if isfield(obj.tmp,'ue')
                if isfield(obj.tmp.ue,'buffer_bits');      s.ue.buffer_bits      = obj.tmp.ue.buffer_bits; end
                if isfield(obj.tmp.ue,'urgent_pkts');      s.ue.urgent_pkts      = obj.tmp.ue.urgent_pkts; end
                if isfield(obj.tmp.ue,'minDeadline_slot'); s.ue.minDeadline_slot = obj.tmp.ue.minDeadline_slot; end
            end

            % UE outage observable flag (derived from internal timers)
            s.ue.inOutage = (obj.ueInOutageUntilSlot > obj.slot);

            %% ---- cell ----
            % PRB totals and usage: try tmp first, else fallback to accumulators if meaningful
            if isfield(obj.tmp,'cell')
                if isfield(obj.tmp.cell,'prbTotal'); s.cell.prbTotal = obj.tmp.cell.prbTotal; end
                if isfield(obj.tmp.cell,'prbUsed');  s.cell.prbUsed  = obj.tmp.cell.prbUsed;  end
            end

            % Derive prbTotal/prbUsed defaults if still zeros and you have numPRB
            if all(s.cell.prbTotal == 0) && obj.numPRB > 0
                s.cell.prbTotal = obj.numPRB * ones(numCell,1);
            end

            % Utilization
            prbTotal = s.cell.prbTotal(:);
            prbUsed  = s.cell.prbUsed(:);
            util = zeros(numCell,1);
            den = prbTotal;
            den(den <= 0) = 1;
            util = prbUsed ./ den;
            util(util < 0) = 0;
            util(util > 1) = 1;
            s.cell.prbUtil = util;

            % tx power
            s.cell.txPower_dBm = obj.txPowerCell_dBm(:);

            % radio parameters per cell
            s.cell.bandwidthHz = obj.bandwidthHz * ones(numCell,1);
            s.cell.scs         = obj.scs * ones(numCell,1);
            s.cell.numPRB      = obj.numPRB * ones(numCell,1);

            % sleep state (default if not maintained)
            if isfield(obj.tmp,'cell') && isfield(obj.tmp.cell,'sleepState')
                s.cell.sleepState = obj.tmp.cell.sleepState;
            elseif ~isfield(s.cell,'sleepState') || numel(s.cell.sleepState) ~= numCell
                s.cell.sleepState = zeros(numCell,1);
            end

            % energy (accumulated)
            s.cell.energy_J = obj.accEnergyJPerCell(:);

            % instant power (optional)
            if isfield(obj.tmp,'cell') && isfield(obj.tmp.cell,'power_W')
                s.cell.power_W = obj.tmp.cell.power_W(:);
            elseif ~isfield(s.cell,'power_W') || numel(s.cell.power_W) ~= numCell
                s.cell.power_W = zeros(numCell,1);
            end

            % HO hysteresis observable (if maintained)
            if isfield(obj.tmp,'cell') && isfield(obj.tmp.cell,'hoHysteresisBaseline_dB')
                s.cell.hoHysteresisBaseline_dB = obj.tmp.cell.hoHysteresisBaseline_dB(:);
            end
            if isfield(obj.tmp,'cell') && isfield(obj.tmp.cell,'hoHysteresisEffective_dB')
                s.cell.hoHysteresisEffective_dB = obj.tmp.cell.hoHysteresisEffective_dB(:);
            end

            %% ---- radio global ----
            if isfield(s,'radio')
                s.radio.noiseFigure_dB   = obj.noiseFigure_dB;
                s.radio.thermalNoise_dBm = obj.thermalNoise_dBm;
            end

            %% ---- channel ----
            % if kernel computes interference/noise per UE, place them in tmp.channel
            if isfield(obj.tmp,'channel')
                if isfield(obj.tmp.channel,'interference_dBm')
                    s.channel.interference_dBm = obj.tmp.channel.interference_dBm(:);
                end
                if isfield(obj.tmp.channel,'noise_dBm')
                    s.channel.noise_dBm = obj.tmp.channel.noise_dBm(:);
                end
            end

            %% ---- events ----
            % HO accumulators (episode-level)
            s.events.handover.countTotal = obj.accHOCount;

            % last HO info (if maintained by kernel)
            if ~isempty(obj.lastHoFromCell)
                % These are optional; kernel must set them at event time.
                % Keep existing values if you don't manage them yet.
            end

            % ping-pong accumulator
            s.events.handover.pingPongCount = obj.accPingPongCount;

            % RLF accumulators
            s.events.rlf.countTotal = obj.accRLFCount;

            %% ---- KPI ----
            s.kpi.throughputBitPerUE = obj.accThroughputBitPerUE(:);
            s.kpi.dropTotal = obj.accDroppedTotal;
            s.kpi.dropURLLC = obj.accDroppedURLLC;

            s.kpi.handoverCount = obj.accHOCount;
            s.kpi.rlfCount      = obj.accRLFCount;

            s.kpi.energyJPerCell = obj.accEnergyJPerCell(:);
            s.kpi.energySignal_J_total = obj.accEnergySignal_J_total;

            s.kpi.prbUtilPerCell = s.cell.prbUtil(:);

            %% ---- assign back ----
            obj.state = s;
        end
    end
end
