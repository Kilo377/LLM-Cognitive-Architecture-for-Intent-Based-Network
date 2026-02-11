classdef RanStateBus
%RANSTATEBUS Standard state bus for ORAN-SIM
%
% 目标：
% 1) RanKernel 只写 state bus
% 2) RIC/xApp 只读 state bus
% 3) 字段语义稳定，后续不返工
%
% 使用方式：
%   state = RanStateBus.init(cfg);
%   state.time.slot = ...;
%   ...
%   RanStateBus.validate(state, cfg);  % 可选，用于调试

    methods (Static)

        function state = init(cfg)
            %INIT Create an empty RanStateBus with fixed fields

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            % -------- time --------
            state.time = struct();
            state.time.slot = 0;
            state.time.t_s  = 0;

            % -------- topology --------
            state.topology = struct();
            state.topology.numCell = numCell;
            state.topology.numUE   = numUE;
            state.topology.gNBPos  = zeros(numCell,3);  % [x y z] meter

            % -------- UE --------
            state.ue = struct();

            % Geometry / association
            state.ue.pos         = zeros(numUE,3);      % [x y z] meter
            state.ue.servingCell = ones(numUE,1);       % cell index 1..numCell

            % Radio measurements
            state.ue.sinr_dB  = zeros(numUE,1);         % serving-cell SINR (dB)
            state.ue.rsrp_dBm = -inf(numUE,numCell);    % RSRP per cell (dBm)

            % Optional PHY feedback fields
            state.ue.cqi  = zeros(numUE,1);             % 1..15 (0 if unknown)
            state.ue.mcs  = zeros(numUE,1);             % last applied MCS (optional)
            state.ue.bler = zeros(numUE,1);             % last estimated BLER (0..1)

            % Buffer / traffic status
            state.ue.buffer_bits = zeros(numUE,1);      % total queued bits
            state.ue.urgent_pkts = zeros(numUE,1);      % count of urgent packets (deadline small)

            % -------- cell --------
            state.cell = struct();

            % Load / resource usage
            state.cell.prbTotal = zeros(numCell,1);     % PRB available per cell per slot
            state.cell.prbUsed  = zeros(numCell,1);     % PRB used in current slot
            state.cell.prbUtil  = zeros(numCell,1);     % prbUsed/prbTotal (instant or smoothed)

            % Power / energy
            state.cell.txPower_dBm = zeros(numCell,1);  % configured Tx power
            state.cell.energy_J    = zeros(numCell,1);  % accumulated or instant energy
            state.cell.sleepState  = zeros(numCell,1);  % 0:on, 1:lightSleep, 2:deepSleep

            % -------- channel (optional) --------
            state.channel = struct();
            state.channel.interference_dBm = nan(numUE,1);  % optional
            state.channel.noise_dBm        = nan(numUE,1);  % optional

            % -------- events --------
            state.events = struct();
            state.events.handover = struct();
            state.events.handover.countTotal = 0;           % accumulated HO count
            state.events.handover.lastUE     = 0;           % last HO UE id (0 if none)
            state.events.handover.lastFrom   = 0;           % last HO source cell
            state.events.handover.lastTo     = 0;           % last HO target cell

            state.events.anomaly = struct();
            state.events.anomaly.flag     = false;          % any anomaly in this tick
            state.events.anomaly.type     = "";             % string label
            state.events.anomaly.severity = 0;              % 0..1
            state.events.anomaly.ueId     = 0;              % 0 if not UE-specific
            state.events.anomaly.cellId   = 0;              % 0 if not cell-specific

            % -------- KPI (episode accumulators exposed safely) --------
            state.kpi = struct();

            % Throughput
            state.kpi.throughputBitPerUE = zeros(numUE,1);  % accumulated delivered bits per UE

            % Drop counters
            state.kpi.dropTotal = 0;                        % accumulated drops
            state.kpi.dropURLLC = 0;                        % accumulated URLLC drops

            % Mobility KPI
            state.kpi.handoverCount = 0;                    % accumulated HO count

            % Energy KPI
            state.kpi.energyJPerCell = zeros(numCell,1);    % accumulated energy per cell

            % Resource KPI
            state.kpi.prbUtilPerCell = zeros(numCell,1);    % running average or current util

        end

        function validate(state, cfg)
            %VALIDATE Basic field and dimension checks
            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            % time
            assert(isfield(state,'time') && isfield(state.time,'slot') && isfield(state.time,'t_s'));

            % topology
            assert(all(size(state.topology.gNBPos) == [numCell,3]));

            % ue
            assert(all(size(state.ue.pos) == [numUE,3]));
            assert(all(size(state.ue.servingCell) == [numUE,1]));
            assert(all(size(state.ue.sinr_dB) == [numUE,1]));
            assert(all(size(state.ue.rsrp_dBm) == [numUE,numCell]));
            assert(all(size(state.ue.buffer_bits) == [numUE,1]));
            assert(all(size(state.ue.urgent_pkts) == [numUE,1]));

            % cell
            assert(all(size(state.cell.prbTotal) == [numCell,1]));
            assert(all(size(state.cell.prbUsed)  == [numCell,1]));
            assert(all(size(state.cell.prbUtil)  == [numCell,1]));
            assert(all(size(state.cell.txPower_dBm) == [numCell,1]));
            assert(all(size(state.cell.energy_J)    == [numCell,1]));
            assert(all(size(state.cell.sleepState)  == [numCell,1]));

            % kpi
            assert(all(size(state.kpi.throughputBitPerUE) == [numUE,1]));
            assert(all(size(state.kpi.energyJPerCell)     == [numCell,1]));
            assert(all(size(state.kpi.prbUtilPerCell)     == [numCell,1]));
        end
    end
end
