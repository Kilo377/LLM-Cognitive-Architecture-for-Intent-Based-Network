classdef RanContext
%RANCONTEXT Runtime state container for modular NR kernel

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
            obj.numPRB = 106; % 可以后续改成公式计算

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

            
            obj.state = RanStateBus.init(cfg);

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
    end
end
