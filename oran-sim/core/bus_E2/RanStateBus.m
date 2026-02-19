classdef RanStateBus
% RANSTATEBUS v3 (Aligned with RanContext v5)
%
% Design:
%   - Kernel writes only
%   - RIC reads only
%   - Add-only evolution
%   - ctrl observable
%   - debug observable

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
            state.time.slot = 0;
            state.time.t_s  = 0;

            %% =======================
            % TOPOLOGY
            %% =======================
            state.topology.numCell = numCell;
            state.topology.numUE   = numUE;
            state.topology.gNBPos  = zeros(numCell,3);

            %% =======================
            % UE
            %% =======================
            state.ue.pos         = zeros(numUE,3);
            state.ue.servingCell = ones(numUE,1);

            state.ue.sinr_dB      = zeros(numUE,1);
            state.ue.rsrp_dBm     = -inf(numUE,numCell);
            state.ue.measRsrp_dBm = -inf(numUE,numCell);

            state.ue.cqi  = zeros(numUE,1);
            state.ue.mcs  = zeros(numUE,1);
            state.ue.bler = zeros(numUE,1);

            state.ue.buffer_bits      = zeros(numUE,1);
            state.ue.urgent_pkts      = zeros(numUE,1);
            state.ue.minDeadline_slot = inf(numUE,1);

            state.ue.inOutage = false(numUE,1);

            %% =======================
            % CELL
            %% =======================
            state.cell.prbTotal = zeros(numCell,1);
            state.cell.prbUsed  = zeros(numCell,1);
            state.cell.prbUtil  = zeros(numCell,1);

            state.cell.txPower_dBm = zeros(numCell,1);
            state.cell.bandwidthHz = zeros(numCell,1);
            state.cell.scs         = zeros(numCell,1);
            state.cell.numPRB      = zeros(numCell,1);

            state.cell.energy_J = zeros(numCell,1);
            state.cell.power_W  = zeros(numCell,1);

            state.cell.sleepState = zeros(numCell,1);

            %% =======================
            % RADIO (global)
            %% =======================
            state.radio.thermalNoise_dBm      = 0;
            state.radio.thermalNoiseCell_dBm  = zeros(numCell,1);
            state.radio.noiseFigure_dB        = 0;

            %% =======================
            % CHANNEL
            %% =======================
            state.channel.interference_dBm = nan(numUE,1);
            state.channel.noise_dBm        = nan(numUE,1);

            %% =======================
            % CTRL (NEW — 核心升级)
            %% =======================
            state.ctrl.basePowerScale = ones(numCell,1);
            state.ctrl.cellSleepState = zeros(numCell,1);
            state.ctrl.selectedUE     = zeros(numCell,1);
            state.ctrl.bandwidthScale = ones(numCell,1);
            state.ctrl.txPowerOffset_dB = zeros(numCell,1);

            state.ctrl.ueBeamId = zeros(numUE,1);
            state.ctrl.beamMode = "static";

            %% =======================
            % EVENTS
            %% =======================
            state.events.handover.countTotal = 0;
            state.events.handover.lastUE     = 0;
            state.events.handover.lastFrom   = 0;
            state.events.handover.lastTo     = 0;
            state.events.handover.pingPongCount = 0;

            state.events.rlf.countTotal = 0;
            state.events.rlf.lastUE     = 0;
            state.events.rlf.lastFrom   = 0;
            state.events.rlf.lastTo     = 0;

            %% =======================
            % KPI
            %% =======================
            state.kpi.throughputBitPerUE = zeros(numUE,1);

            state.kpi.dropTotal = 0;
            state.kpi.dropURLLC = 0;

            state.kpi.handoverCount = 0;
            state.kpi.rlfCount      = 0;

            state.kpi.energyJPerCell = zeros(numCell,1);
            state.kpi.energySignal_J_total = 0;

            state.kpi.prbUtilPerCell = zeros(numCell,1);

            %% =======================
            % DEBUG TRACE (NEW)
            %% =======================
            state.debug.scheduler.selectedUE = zeros(numCell,1);
            state.debug.scheduler.reason     = strings(numCell,1);

            state.debug.energy.loadRatio = zeros(numCell,1);
            state.debug.radio.effectiveTxPower_dBm = zeros(numCell,1);
        end


        %% =========================================================
        % VALIDATE
        %% =========================================================
        function validate(state, cfg)

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            assert(all(size(state.ue.pos) == [numUE,3]));
            assert(all(size(state.cell.prbTotal) == [numCell,1]));
            assert(all(size(state.ctrl.basePowerScale) == [numCell,1]));
            assert(all(size(state.ctrl.selectedUE) == [numCell,1]));
            assert(all(size(state.ctrl.ueBeamId) == [numUE,1]));
        end
    end
end

