classdef RanStateBus
%RANSTATEBUS Standard state bus for ORAN-SIM (v2 aligned with RanContext)
%
% Design principles:
% 1) Kernel writes only
% 2) RIC/xApp reads only
% 3) Stable semantics
% 4) Add-only evolution rule

    methods (Static)

        %% =========================================================
        % INIT
        %% =========================================================
        function state = init(cfg)

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            %% =======================
            % TIME
            %% =======================
            state.time = struct();
            state.time.slot = 0;
            state.time.t_s  = 0;

            %% =======================
            % TOPOLOGY
            %% =======================
            state.topology = struct();
            state.topology.numCell = numCell;
            state.topology.numUE   = numUE;
            state.topology.gNBPos  = zeros(numCell,3);

            %% =======================
            % UE
            %% =======================
            state.ue = struct();

            state.ue.pos         = zeros(numUE,3);
            state.ue.servingCell = ones(numUE,1);

            state.ue.sinr_dB      = zeros(numUE,1);
            state.ue.rsrp_dBm     = -inf(numUE,numCell);
            state.ue.measRsrp_dBm = -inf(numUE,numCell);

            % PHY feedback
            state.ue.cqi  = zeros(numUE,1);
            state.ue.mcs  = zeros(numUE,1);
            state.ue.bler = zeros(numUE,1);

            % Traffic observability
            state.ue.buffer_bits      = zeros(numUE,1);
            state.ue.urgent_pkts      = zeros(numUE,1);
            state.ue.minDeadline_slot = inf(numUE,1);

            % UE RLF state (observable level only)
            state.ue.inOutage = false(numUE,1);

            %% =======================
            % CELL
            %% =======================
            state.cell = struct();

            % Resource usage
            state.cell.prbTotal = zeros(numCell,1);
            state.cell.prbUsed  = zeros(numCell,1);
            state.cell.prbUtil  = zeros(numCell,1);

            % Radio config
            state.cell.txPower_dBm = zeros(numCell,1);
            state.cell.bandwidthHz = zeros(numCell,1);
            state.cell.scs         = zeros(numCell,1);
            state.cell.numPRB      = zeros(numCell,1);

            % Energy
            state.cell.energy_J = zeros(numCell,1);
            state.cell.power_W  = zeros(numCell,1);

            % Sleep
            state.cell.sleepState = zeros(numCell,1);

            % HO config (observable effective values)
            state.cell.hoHysteresisBaseline_dB  = zeros(numCell,1);
            state.cell.hoHysteresisEffective_dB = zeros(numCell,1);

            %% =======================
            % RADIO GLOBAL
            %% =======================
            state.radio = struct();
            state.radio.thermalNoise_dBm = 0;
            state.radio.noiseFigure_dB   = 0;

            %% =======================
            % CHANNEL
            %% =======================
            state.channel = struct();
            state.channel.interference_dBm = nan(numUE,1);
            state.channel.noise_dBm        = nan(numUE,1);

            %% =======================
            % EVENTS
            %% =======================
            state.events = struct();

            % Handover
            state.events.handover = struct();
            state.events.handover.countTotal    = 0;
            state.events.handover.lastUE        = 0;
            state.events.handover.lastFrom      = 0;
            state.events.handover.lastTo        = 0;
            state.events.handover.pingPongCount = 0;
            state.events.handover.lastPingPongUE = 0;

            % RLF
            state.events.rlf = struct();
            state.events.rlf.countTotal = 0;
            state.events.rlf.lastUE     = 0;
            state.events.rlf.lastFrom   = 0;
            state.events.rlf.lastTo     = 0;

            % Anomaly
            state.events.anomaly = struct();
            state.events.anomaly.flag     = false;
            state.events.anomaly.type     = "";
            state.events.anomaly.severity = 0;
            state.events.anomaly.ueId     = 0;
            state.events.anomaly.cellId   = 0;

            %% =======================
            % KPI (episode accumulators)
            %% =======================
            state.kpi = struct();

            state.kpi.throughputBitPerUE = zeros(numUE,1);

            state.kpi.dropTotal = 0;
            state.kpi.dropURLLC = 0;

            state.kpi.handoverCount = 0;
            state.kpi.rlfCount      = 0;

            state.kpi.energyJPerCell = zeros(numCell,1);
            state.kpi.energySignal_J_total = 0;

            state.kpi.prbUtilPerCell = zeros(numCell,1);
        end


        %% =========================================================
        % VALIDATE
        %% =========================================================
        function validate(state, cfg)

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            % ---- time
            assert(isfield(state,'time'));
            assert(isfield(state.time,'slot'));
            assert(isfield(state.time,'t_s'));

            % ---- topology
            assert(isfield(state,'topology'));
            assert(all(size(state.topology.gNBPos) == [numCell,3]));

            % ---- ue
            assert(isfield(state,'ue'));
            assert(all(size(state.ue.pos) == [numUE,3]));
            assert(all(size(state.ue.servingCell) == [numUE,1]));
            assert(all(size(state.ue.sinr_dB) == [numUE,1]));
            assert(all(size(state.ue.rsrp_dBm) == [numUE,numCell]));
            assert(all(size(state.ue.measRsrp_dBm) == [numUE,numCell]));
            assert(all(size(state.ue.buffer_bits) == [numUE,1]));
            assert(all(size(state.ue.urgent_pkts) == [numUE,1]));
            assert(all(size(state.ue.minDeadline_slot) == [numUE,1]));

            % ---- cell
            assert(isfield(state,'cell'));
            assert(all(size(state.cell.prbTotal) == [numCell,1]));
            assert(all(size(state.cell.prbUsed)  == [numCell,1]));
            assert(all(size(state.cell.prbUtil)  == [numCell,1]));
            assert(all(size(state.cell.txPower_dBm) == [numCell,1]));
            assert(all(size(state.cell.numPRB) == [numCell,1]));

            % ---- events
            assert(isfield(state,'events'));
            assert(isfield(state.events,'handover'));
            assert(isfield(state.events,'rlf'));

            % ---- kpi
            assert(isfield(state,'kpi'));
            assert(all(size(state.kpi.throughputBitPerUE) == [numUE,1]));
            assert(all(size(state.kpi.energyJPerCell)     == [numCell,1]));
            assert(all(size(state.kpi.prbUtilPerCell)     == [numCell,1]));
        end
    end
end
