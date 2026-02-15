classdef RanKernelNR
%RANKERNELNR Modular NR system-level kernel
%
% Orchestrates:
%   Mobility
%   Traffic
%   Beamforming
%   Radio
%   Handover + RLF
%   Scheduler
%   PHY
%   Energy
%   KPI
%   State export

    properties
        cfg
        scenario

        ctx

        % Models
        mobilityModel
        trafficModel
        beamModel
        radioModel
        hoModel
        schedulerModel
        phyModel
        energyModel
        kpiModel
    end

    methods

        %% ===============================
        % Constructor
        %% ===============================
        function obj = RanKernelNR(cfg, scenario)

            obj.cfg      = cfg;
            obj.scenario = scenario;

            % Context
            obj.ctx = RanContext(cfg, scenario);

            % Models (assume scenario already contains mobility/traffic)
            obj.mobilityModel  = scenario.mobility.model;
            obj.trafficModel   = scenario.traffic.model;

            obj.beamModel      = BeamformingModel();
            obj.radioModel     = RadioModel();
            obj.hoModel        = HandoverModel();
            obj.schedulerModel = SchedulerPRBModel();
            obj.phyModel       = PhyServiceModel(cfg, scenario);
            obj.energyModel    = EnergyModelBS();
            obj.kpiModel       = KPIModel(); % if you implemented it

            % Initial radio measurement + association
            obj.ctx = obj.radioModel.step(obj.ctx);
            obj.ctx = obj.hoModel.step(obj.ctx);

        end

        %% ===============================
        % One slot step (baseline or action-aware)
        %% ===============================
        function obj = step(obj, action)

            if nargin < 2
                action = [];
            end

            % ===== Slot advance =====
            obj.ctx = obj.ctx.nextSlot();
            obj.ctx = obj.ctx.setAction(action);

            %% ===== 1. Mobility =====
            [obj.mobilityModel, pos2d] = ...
                obj.mobilityModel.step(obj.ctx.dt);

            obj.ctx.uePos(:,1:2) = pos2d;

            %% ===== 2. Traffic =====
            obj.trafficModel = obj.trafficModel.step();
            obj.trafficModel = obj.trafficModel.decreaseDeadline();
            [obj.trafficModel, dropped] = ...
                obj.trafficModel.dropExpired();

            obj.ctx.scenario.traffic.model = obj.trafficModel;

            if ~isempty(dropped)
                obj.ctx.accDroppedTotal = ...
                    obj.ctx.accDroppedTotal + numel(dropped);

                for i = 1:numel(dropped)
                    if dropped(i).type == "URLLC" || ...
                       strcmp(dropped(i).type,'URLLC')
                        obj.ctx.accDroppedURLLC = ...
                            obj.ctx.accDroppedURLLC + 1;
                    end
                end
            end

            %% ===== 3. Beamforming =====
            [obj.beamModel, obj.ctx] = obj.beamModel.step(obj.ctx);

            %% ===== 4. Radio =====
            obj.ctx = obj.radioModel.step(obj.ctx);

            %% ===== 5. Handover + RLF =====
            obj.ctx = obj.hoModel.step(obj.ctx);

            %% ===== 6. Scheduler =====
            obj.ctx = obj.schedulerModel.step(obj.ctx);

            %% ===== 7. PHY =====
            [obj.phyModel, obj.ctx] = obj.phyModel.step(obj.ctx);

            %% ===== 8. Energy =====
            obj.ctx = obj.energyModel.step(obj.ctx);

            %% ===== 9. KPI =====
            if ~isempty(obj.kpiModel)
                obj.ctx = obj.kpiModel.step(obj.ctx);
            end


        end

        %% ===============================
        % Get state for RIC
        %% ===============================
        function state = getState(obj)

            state = RanStateBus.init(obj.cfg);

            numUE   = obj.cfg.scenario.numUE;
            numCell = obj.cfg.scenario.numCell;

            s = state;

            %% time
            s.time.slot = obj.ctx.slot;
            s.time.t_s  = obj.ctx.slot * obj.ctx.dt;

            %% topology
            s.topology.gNBPos = obj.scenario.topology.gNBPos;

            %% UE
            s.ue.pos         = obj.ctx.uePos;
            s.ue.servingCell = obj.ctx.servingCell;
            s.ue.sinr_dB     = obj.ctx.sinr_dB;
            s.ue.rsrp_dBm    = obj.ctx.rsrp_dBm;

            if isfield(obj.ctx.tmp,'lastCQIPerUE')
                s.ue.cqi = obj.ctx.tmp.lastCQIPerUE;
            end
            if isfield(obj.ctx.tmp,'lastMCSPerUE')
                s.ue.mcs = obj.ctx.tmp.lastMCSPerUE;
            end
            if isfield(obj.ctx.tmp,'lastBLERPerUE')
                s.ue.bler = obj.ctx.tmp.lastBLERPerUE;
            end

            % buffer
            buf = zeros(numUE,1);
            urg = zeros(numUE,1);
            minDL = inf(numUE,1);

            for u = 1:numUE
                q = obj.trafficModel.getQueue(u);
                if isempty(q), continue; end
                buf(u) = sum([q.size]);
                d = [q.deadline];
                urg(u) = sum(isfinite(d) & d <= 5);
                if any(isfinite(d))
                    minDL(u) = min(d(isfinite(d)));
                end
            end

            s.ue.buffer_bits      = buf;
            s.ue.urgent_pkts      = urg;
            s.ue.minDeadline_slot = minDL;

            %% cell
            s.cell.prbTotal = obj.ctx.numPRB * ones(numCell,1);

            if isfield(obj.ctx.tmp,'lastPRBUsedPerCell')
                s.cell.prbUsed = obj.ctx.tmp.lastPRBUsedPerCell;
                s.cell.prbUtil = ...
                    s.cell.prbUsed ./ max(s.cell.prbTotal,1);
            end

            s.cell.txPower_dBm = ...
                obj.ctx.txPowerCell_dBm * ones(numCell,1);

            s.cell.energy_J = obj.ctx.accEnergyJPerCell;

            if isfield(obj.ctx.tmp,'energyWPerCell')
                s.cell.power_W = obj.ctx.tmp.energyWPerCell;
            end

            %% events
            s.events.handover.countTotal = obj.ctx.accHOCount;
            s.events.handover.pingPongCount = obj.ctx.accPingPongCount;
            s.events.rlf.countTotal = obj.ctx.accRLFCount;

            if isfield(obj.ctx.tmp,'events')
                ev = obj.ctx.tmp.events;

                if isfield(ev,'lastHOue')
                    s.events.handover.lastUE   = ev.lastHOue;
                    s.events.handover.lastFrom = ev.lastHOfrom;
                    s.events.handover.lastTo   = ev.lastHOto;
                end
                if isfield(ev,'rlfOccured') && ev.rlfOccured
                    s.events.rlf.lastUE   = ev.rlfUE;
                    s.events.rlf.lastFrom = ev.rlfFrom;
                    s.events.rlf.lastTo   = ev.rlfTo;
                end
            end

            %% kpi
            s.kpi.throughputBitPerUE = obj.ctx.accThroughputBitPerUE;
            s.kpi.dropTotal          = obj.ctx.accDroppedTotal;
            s.kpi.dropURLLC          = obj.ctx.accDroppedURLLC;
            s.kpi.handoverCount      = obj.ctx.accHOCount;
            s.kpi.energyJPerCell     = obj.ctx.accEnergyJPerCell;

            state = s;
        end

        %% ===============================
        % Final report
        %% ===============================
        function report = finalize(obj)

            T = obj.cfg.sim.slotPerEpisode * obj.ctx.dt;

            report.throughput_bps_total = ...
                sum(obj.ctx.accThroughputBitPerUE) / T;

            report.handover_count = obj.ctx.accHOCount;
            report.rlf_count      = obj.ctx.accRLFCount;

            report.drop_total     = obj.ctx.accDroppedTotal;
            report.drop_urllc     = obj.ctx.accDroppedURLLC;

            report.energy_J_total = sum(obj.ctx.accEnergyJPerCell);

            report.energy_eff_bit_per_J = ...
                sum(obj.ctx.accThroughputBitPerUE) / ...
                max(report.energy_J_total,1e-9);
        end
    end
end
