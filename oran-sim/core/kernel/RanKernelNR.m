classdef RanKernelNR
%RANKERNELNR Modular NR RAN kernel (Stage 3: +Energy +KPI)
%
% External APIs unchanged:
%   stepBaseline
%   stepWithAction
%   getState
%   finalize
%
% Internal pipeline:
%   mobility -> traffic -> radio -> handover -> scheduler -> phy -> energy -> kpi -> state

    properties
        cfg
        scenario

        % Runtime context
        ctx

        % Models
        radio
        ho
        scheduler
        phyService
        energy
        kpi

        % State bus
        state
    end

    methods
        %% =========================================================
        % Constructor
        %% =========================================================
        function obj = RanKernelNR(cfg, scenario)

            obj.cfg      = cfg;
            obj.scenario = scenario;

            % -------- Context init --------
            obj.ctx = RanContext;
            obj.ctx.cfg      = cfg;
            obj.ctx.scenario = scenario;

            obj.ctx.slot = 0;
            obj.ctx.dt   = cfg.sim.slotDuration;

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            % UE init
            obj.ctx.uePos       = scenario.topology.ueInitPos;
            obj.ctx.servingCell = ones(numUE,1);
            obj.ctx.rsrp_dBm    = -inf(numUE, numCell);
            obj.ctx.sinr_dB     = zeros(numUE,1);

            obj.ctx.hoTimer            = zeros(numUE,1);
            obj.ctx.ueBlockedUntilSlot = zeros(numUE,1);

            % Cell init
            obj.ctx.rrPtr = ones(numCell,1);

            % Radio params
            obj.ctx.bandwidthHz     = scenario.radio.bandwidth;
            obj.ctx.numPRB          = 106;
            obj.ctx.txPowerCell_dBm = scenario.radio.txPower.cell;

            % Energy params (kept for reference; actual model stores its own params too)
            obj.ctx.P0_W = scenario.energy.P0;
            obj.ctx.k_pa = scenario.energy.k;

            % KPI accumulators
            obj.ctx.accThroughputBitPerUE = zeros(numUE,1);
            obj.ctx.accPRBUsedPerCell     = zeros(numCell,1);
            obj.ctx.accPRBTotalPerCell    = zeros(numCell,1);
            obj.ctx.accHOCount            = 0;
            obj.ctx.accDroppedTotal       = 0;
            obj.ctx.accDroppedURLLC       = 0;
            obj.ctx.accEnergyJPerCell     = zeros(numCell,1);

            % -------- Models --------
            obj.radio      = RadioModel;
            obj.ho         = HandoverModel;
            obj.scheduler  = SchedulerPRBModel;                 % must return ctx (fixed version)
            obj.phyService = PhyServiceModel(cfg, scenario);
            obj.energy     = LoadAwareEnergyModel(cfg, scenario);
            obj.kpi        = BasicKPIModel;

            % -------- State --------
            obj.state = RanStateBus.init(cfg);

            % -------- Initial tick (radio + association) --------
            obj.ctx = obj.ctx.clearSlotTemp();
            obj.ctx.action = RanActionBus.init(cfg);

            obj.ctx = obj.radio.step(obj.ctx);
            obj.ctx.servingCell = obj.initialAssociation(obj.ctx);

            % Build state once
            obj.state = RanStateBus.buildFromContext(obj.state, obj.ctx);
        end

        %% =========================================================
        % Baseline step
        %% =========================================================
        function obj = stepBaseline(obj)
            action = RanActionBus.init(obj.cfg);
            obj = obj.stepWithAction(action);
        end

        %% =========================================================
        % Action-aware step
        %% =========================================================
        function obj = stepWithAction(obj, action)

            % time
            obj.ctx.slot   = obj.ctx.slot + 1;
            obj.ctx.action = action;

            % clear per-slot temp
            obj.ctx = obj.ctx.clearSlotTemp();

            % -------- mobility --------
            [obj.ctx.scenario.mobility.model, pos2d] = ...
                obj.ctx.scenario.mobility.model.step(obj.ctx.dt);
            obj.ctx.uePos(:,1:2) = pos2d;

            % -------- traffic --------
            obj.ctx.scenario.traffic.model = obj.ctx.scenario.traffic.model.step();
            obj.ctx.scenario.traffic.model = obj.ctx.scenario.traffic.model.decreaseDeadline();

            [obj.ctx.scenario.traffic.model, dropped] = ...
                obj.ctx.scenario.traffic.model.dropExpired();

            obj.ctx = obj.accountDrops(obj.ctx, dropped);

            % -------- radio --------
            obj.ctx = obj.radio.step(obj.ctx);

            % -------- handover (+interruption) --------
            obj.ctx = obj.ho.step(obj.ctx);

            % -------- scheduler (PRB allocation) --------
            obj.ctx = obj.scheduler.step(obj.ctx);

            % -------- phy service (serve queues + feedback + PRB used) --------
            [obj.phyService, obj.ctx] = obj.phyService.step(obj.ctx);

            % -------- energy --------
            obj.ctx = obj.energy.step(obj.ctx);

            % -------- derived KPI --------
            obj.ctx = obj.kpi.step(obj.ctx);

            % -------- state bus --------
            obj.state = RanStateBus.buildFromContext(obj.state, obj.ctx);

            % Optional: expose derived KPI to state
            % If you want, add this block; harmless if absent.
            if isfield(obj.ctx.tmp,'derivedKPI')
                obj.state.kpi.derived = obj.ctx.tmp.derivedKPI;
            end
        end

        %% =========================================================
        % Public
        %% =========================================================
        function state = getState(obj)
            state = obj.state;
        end

        function report = finalize(obj)

            T = obj.cfg.sim.slotPerEpisode * obj.ctx.dt;

            report.throughput_bps_total = sum(obj.ctx.accThroughputBitPerUE) / T;

            report.prb_util_perCell = ...
                obj.ctx.accPRBUsedPerCell ./ max(obj.ctx.accPRBTotalPerCell,1);

            report.handover_count = obj.ctx.accHOCount;
            report.dropped_total  = obj.ctx.accDroppedTotal;
            report.dropped_urllc  = obj.ctx.accDroppedURLLC;

            report.energy_J_total = sum(obj.ctx.accEnergyJPerCell);

            report.energy_eff_bit_per_J = ...
                sum(obj.ctx.accThroughputBitPerUE) / max(report.energy_J_total,1e-9);

            % Optional: include derived KPI snapshot
            if isfield(obj.ctx.tmp,'derivedKPI')
                report.derivedKPI = obj.ctx.tmp.derivedKPI;
            end
        end
    end

    methods (Access = private)

        function servingCell = initialAssociation(~, ctx)
            [~, best] = max(ctx.rsrp_dBm, [], 2);
            servingCell = best;
        end

        function ctx = accountDrops(~, ctx, dropped)

            if isempty(dropped)
                return;
            end

            ctx.accDroppedTotal = ctx.accDroppedTotal + numel(dropped);

            for i = 1:numel(dropped)
                if strcmp(dropped(i).type,'URLLC')
                    ctx.accDroppedURLLC = ctx.accDroppedURLLC + 1;
                end
            end
        end
    end
end
