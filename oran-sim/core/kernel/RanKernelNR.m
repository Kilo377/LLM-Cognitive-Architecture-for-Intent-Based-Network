classdef RanKernelNR
%RANKERNELNR Modular NR system-level kernel (Action-aware version)
%
% Key changes:
% 1) After KPI step, publish ctx.state via ctx.updateStateBus()
% 2) getState() returns ctx.state directly (no re-init / no recompute)

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

        actionApplierModel
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

            % Models
            obj.mobilityModel  = scenario.mobility.model;
            obj.trafficModel   = scenario.traffic.model;

            obj.beamModel      = BeamformingModel();
            obj.radioModel     = RadioModel();
            obj.hoModel        = HandoverModel();
            obj.schedulerModel = SchedulerPRBModel();
            obj.phyModel       = PhyServiceModel(cfg, scenario);
            obj.energyModel    = EnergyModelBS();
            obj.kpiModel       = KPIModel();

            obj.actionApplierModel = ActionApplierModel();

            % Initial radio + association
            obj.ctx = obj.radioModel.step(obj.ctx);
            obj.ctx = obj.hoModel.step(obj.ctx);

            % Publish initial state
            obj.ctx = obj.ctx.updateStateBus();
        end


        %% ===============================
        % One slot step
        %% ===============================
        function obj = step(obj, action)

            if nargin < 2
                action = [];
            end

            % ===== Slot advance =====
            obj.ctx = obj.ctx.nextSlot();

            % ===== Apply action FIRST =====
            obj.ctx = obj.actionApplierModel.step(obj.ctx, action);

            %% ===== 1. Mobility =====
            [obj.mobilityModel, pos2d] = obj.mobilityModel.step(obj.ctx.dt);
            obj.ctx.uePos(:,1:2) = pos2d;

            %% ===== 2. Traffic =====
            obj.trafficModel = obj.trafficModel.step();
            obj.trafficModel = obj.trafficModel.decreaseDeadline();
            [obj.trafficModel, dropped] = obj.trafficModel.dropExpired();

            obj.ctx.scenario.traffic.model = obj.trafficModel;

            if ~isempty(dropped)
                obj.ctx.accDroppedTotal = obj.ctx.accDroppedTotal + numel(dropped);

                for i = 1:numel(dropped)
                    if dropped(i).type == "URLLC" || strcmp(dropped(i).type,'URLLC')
                        obj.ctx.accDroppedURLLC = obj.ctx.accDroppedURLLC + 1;
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
            obj.ctx = obj.kpiModel.step(obj.ctx);

            %% ===== 10. Publish state bus =====
            obj.ctx = obj.ctx.updateStateBus();
        end


        %% ===============================
        % Get state for RIC
        %% ===============================
        function state = getState(obj)
            % Ensure latest publish (safe even if already published in step)
            obj.ctx = obj.ctx.updateStateBus();
            state = obj.ctx.state;
        end


        %% ===============================
        % Final report
        %% ===============================
        function report = finalize(obj)

            T = obj.cfg.sim.slotPerEpisode * obj.ctx.dt;

            report.throughput_bps_total = sum(obj.ctx.accThroughputBitPerUE) / max(T,1e-12);

            report.handover_count = obj.ctx.accHOCount;
            report.rlf_count      = obj.ctx.accRLFCount;

            report.drop_total     = obj.ctx.accDroppedTotal;
            report.drop_urllc     = obj.ctx.accDroppedURLLC;

            report.energy_J_total = sum(obj.ctx.accEnergyJPerCell);

            report.energy_eff_bit_per_J = ...
                sum(obj.ctx.accThroughputBitPerUE) / max(report.energy_J_total,1e-9);
        end
    end
end
