classdef RanKernelNR
%RANKERNELNR Modular NR system-level kernel (Action-aware, ctrl-unified, debug-trace)
%
% Goals:
%   1) ActionApplier is the ONLY place to translate action -> ctx.ctrl and
%      reset runtime knobs from ctx.baseline each slot.
%   2) All models consume ctx.ctrl + runtime knobs.
%   3) State bus is published once per slot at the end of step().
%   4) Unified debug interface: action.debug.enableVerbose drives per-stage prints.
%
% Debug contract:
%   - RIC sets action.debug.enableVerbose = true
%   - Optional: action.debug.printSlot = N (0 means all slots)
%   - Kernel prints stage-by-stage chain values and checks for broken links.
%
% Notes:
%   - nextSlot() clears ctx.tmp. Models must write per-slot debug under ctx.tmp.debug.*
%   - ActionApplier should also populate ctx.tmp.debug.action for observability.
%
% Dependency order:
%   nextSlot -> ActionApplier -> Mobility -> Traffic -> Beam -> Radio -> HO -> Scheduler -> PHY -> Energy -> KPI -> updateStateBus

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

            % Models (scenario-owned models are handles in your setup)
            obj.mobilityModel  = scenario.mobility.model;
            obj.trafficModel   = scenario.traffic.model;

            obj.beamModel      = BeamformingModel();   % should read ctx.ctrl not ctx.action
            obj.radioModel     = RadioModel();         % should read ctx.ctrl not ctx.action
            obj.hoModel        = HandoverModel();      % should read ctx.ctrl not ctx.action
            obj.schedulerModel = SchedulerPRBModel();  % reads ctx.ctrl
            obj.phyModel       = PhyServiceModel(cfg, scenario);
            obj.energyModel    = EnergyModelBS();      % reads ctx.ctrl only
            obj.kpiModel       = KPIModel();

            obj.actionApplierModel = ActionApplierModel();

            % --------------------------------------------------
            % Slot-0 initialization
            % --------------------------------------------------
            obj.ctx = obj.actionApplierModel.step(obj.ctx, RanActionBus.init(cfg));
            obj.ctx = obj.radioModel.step(obj.ctx);
            obj.ctx = obj.hoModel.step(obj.ctx);
            obj.ctx = obj.ctx.updateStateBus();
        end

        %% ===============================
        % One slot step
        %% ===============================
        function obj = step(obj, action)

            if nargin < 2
                action = [];
            end

            % --------------------------------------------------
            % 0) Advance slot (clears tmp)
            % --------------------------------------------------
            obj.ctx = obj.ctx.nextSlot();

            % --------------------------------------------------
            % 0.1) Apply action FIRST (build ctx.ctrl + reset knobs)
            % --------------------------------------------------
            obj.ctx = obj.actionApplierModel.step(obj.ctx, action);

            % --------------------------------------------------
            % Debug gate
            % --------------------------------------------------
            [dbgOn, dbgThisSlot] = obj.debugGate(action, obj.ctx.slot);

            if dbgOn && dbgThisSlot
                obj.printHeader(action);
                obj.printChainSnapshot("After ActionApplier", obj.ctx);
            end

            % --------------------------------------------------
            % 1) Mobility
            % --------------------------------------------------
            [obj.mobilityModel, pos2d] = obj.mobilityModel.step(obj.ctx.dt);
            obj.ctx.uePos(:,1:2) = pos2d;

            if dbgOn && dbgThisSlot
                obj.printChainSnapshot("After Mobility", obj.ctx);
            end

            % --------------------------------------------------
            % 2) Traffic
            % --------------------------------------------------
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

            if dbgOn && dbgThisSlot
                obj.attachTrafficDebug();
                obj.printChainSnapshot("After Traffic", obj.ctx);
            end

            % --------------------------------------------------
            % 3) Beamforming
            % --------------------------------------------------
            [obj.beamModel, obj.ctx] = obj.beamModel.step(obj.ctx);

            if dbgOn && dbgThisSlot
                obj.printChainSnapshot("After Beamforming", obj.ctx);
            end

            % --------------------------------------------------
            % 4) Radio
            % --------------------------------------------------
            obj.ctx = obj.radioModel.step(obj.ctx);

            if dbgOn && dbgThisSlot
                obj.printChainSnapshot("After Radio", obj.ctx);
            end

            % --------------------------------------------------
            % 5) Handover + RLF
            % --------------------------------------------------
            obj.ctx = obj.hoModel.step(obj.ctx);

            if dbgOn && dbgThisSlot
                obj.printChainSnapshot("After HO/RLF", obj.ctx);
            end

            % --------------------------------------------------
            % 6) Scheduler
            % --------------------------------------------------
            obj.ctx = obj.schedulerModel.step(obj.ctx);

            if dbgOn && dbgThisSlot
                obj.printChainSnapshot("After Scheduler", obj.ctx);
            end

            % --------------------------------------------------
            % 7) PHY
            % --------------------------------------------------
            [obj.phyModel, obj.ctx] = obj.phyModel.step(obj.ctx);

            if dbgOn && dbgThisSlot
                obj.printChainSnapshot("After PHY", obj.ctx);
            end

            % --------------------------------------------------
            % 8) Energy
            % --------------------------------------------------
            obj.ctx = obj.energyModel.step(obj.ctx);

            if dbgOn && dbgThisSlot
                obj.printChainSnapshot("After Energy", obj.ctx);
            end

            % --------------------------------------------------
            % 9) KPI
            % --------------------------------------------------
            obj.ctx = obj.kpiModel.step(obj.ctx);

            if dbgOn && dbgThisSlot
                obj.printChainSnapshot("After KPI", obj.ctx);
            end

            % --------------------------------------------------
            % 10) Publish state bus (for RIC/xApps)
            % --------------------------------------------------
            obj.ctx = obj.ctx.updateStateBus();

            if dbgOn && dbgThisSlot
                obj.printChainSnapshot("After updateStateBus", obj.ctx);
                obj.printFooter();
            end
        end

        %% ===============================
        % Get state for RIC
        %% ===============================
        function state = getState(obj)
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

    %% =========================================================
    % Debug helpers (private)
    %% =========================================================
    methods (Access = private)

        function [dbgOn, dbgThisSlot] = debugGate(~, action, slotNow)
            dbgOn = false;
            dbgThisSlot = false;

            if isempty(action) || ~isstruct(action)
                return;
            end

            if ~isfield(action,'debug')
                return;
            end

            if isfield(action.debug,'enableVerbose') && logical(action.debug.enableVerbose)
                dbgOn = true;
            end

            if ~dbgOn
                return;
            end

            if ~isfield(action.debug,'printSlot')
                dbgThisSlot = true;
                return;
            end

            ps = action.debug.printSlot;

            if isempty(ps) || ps == 0
                dbgThisSlot = true;
                return;
            end

            dbgThisSlot = (slotNow == ps);
        end

        function printHeader(~, action)
            slotStr = "";
            if isfield(action,'debug') && isfield(action.debug,'printSlot')
                slotStr = string(action.debug.printSlot);
            end

            disp("==================================================");
            disp("[RanKernelNR DEBUG] Slot Trace Enabled");
            if strlength(slotStr) > 0
                disp("debug.printSlot=" + slotStr);
            end
            disp("==================================================");
        end

        function printFooter(~)
            disp("==================================================");
            disp("[RanKernelNR DEBUG] End of Slot Trace");
            disp("==================================================");
        end

        function attachTrafficDebug(obj)
            if ~isfield(obj.ctx.tmp,'debug') || isempty(obj.ctx.tmp.debug)
                obj.ctx.tmp.debug = struct();
            end
            if ~isfield(obj.ctx.tmp.debug,'traffic') || isempty(obj.ctx.tmp.debug.traffic)
                obj.ctx.tmp.debug.traffic = struct();
            end

            numUE = obj.ctx.cfg.scenario.numUE;

            buf = zeros(numUE,1);
            urgent = zeros(numUE,1);
            mindl = inf(numUE,1);

            for u = 1:numUE
                q = obj.trafficModel.getQueue(u);
                if isempty(q)
                    continue;
                end
                buf(u) = sum([q.size]);
                urgent(u) = sum(arrayfun(@(p) isfinite(p.deadline) && p.deadline <= 2, q));
                dls = arrayfun(@(p) p.deadline, q);
                if ~isempty(dls)
                    mindl(u) = min(dls);
                end
            end

            obj.ctx.tmp.debug.traffic.buffer_bits = buf;
            obj.ctx.tmp.debug.traffic.urgent_pkts = urgent;
            obj.ctx.tmp.debug.traffic.minDeadline_slot = mindl;

            if ~isfield(obj.ctx.tmp,'ue') || isempty(obj.ctx.tmp.ue)
                obj.ctx.tmp.ue = struct();
            end
            obj.ctx.tmp.ue.buffer_bits = buf;
            obj.ctx.tmp.ue.urgent_pkts = urgent;
            obj.ctx.tmp.ue.minDeadline_slot = mindl;
        end

        function printChainSnapshot(~, tag, ctx)

            disp("---- " + string(tag) + " ----");
            disp("slot=" + string(ctx.slot) + ...
                 "  t_s=" + string(double(ctx.slot)*double(ctx.dt)));

            % ctrl snapshot
            if isfield(ctx,'ctrl') && ~isempty(ctx.ctrl)
                if isfield(ctx.ctrl,'cellSleepState')
                    disp("ctrl.cellSleepState=" + mat2str(ctx.ctrl.cellSleepState(:).'));
                end
                if isfield(ctx.ctrl,'bandwidthScale')
                    disp("ctrl.bandwidthScale=" + mat2str(ctx.ctrl.bandwidthScale(:).'));
                end
                if isfield(ctx.ctrl,'txPowerOffset_dB')
                    disp("ctrl.txPowerOffset_dB=" + mat2str(ctx.ctrl.txPowerOffset_dB(:).'));
                end
                if isfield(ctx.ctrl,'basePowerScale')
                    disp("ctrl.basePowerScale=" + mat2str(ctx.ctrl.basePowerScale(:).'));
                end
            end

            % runtime knobs
            disp("cell.txPowerCell_dBm=" + mat2str(ctx.txPowerCell_dBm(:).'));
            disp("cell.bandwidthHzPerCell=" + mat2str(ctx.bandwidthHzPerCell(:).'));
            disp("cell.numPRBPerCell=" + mat2str(ctx.numPRBPerCell(:).'));

            % radio quality
            if ~isempty(ctx.sinr_dB)
                disp("UE meanSINR_dB=" + string(mean(ctx.sinr_dB)));
            end

            % scheduler output
            if isfield(ctx.tmp,'lastPRBUsedPerCell')
                disp("tmp.lastPRBUsedPerCell=" + mat2str(ctx.tmp.lastPRBUsedPerCell(:).'));
            end

            % PHY feedback
            if isfield(ctx.tmp,'lastMCSPerUE')
                disp("tmp.meanMCS=" + string(mean(ctx.tmp.lastMCSPerUE)));
            end
            if isfield(ctx.tmp,'lastBLERPerUE')
                disp("tmp.meanBLER=" + string(mean(ctx.tmp.lastBLERPerUE)));
            end

            % KPI quick view
            if isfield(ctx.tmp,'kpi') && isfield(ctx.tmp.kpi,'throughput_Mbps_total')
                disp("kpi.thr_Mbps_total=" + string(ctx.tmp.kpi.throughput_Mbps_total));
                disp("kpi.dropRatio=" + string(ctx.tmp.kpi.dropRatio));
                disp("kpi.energy_J_total=" + string(ctx.tmp.kpi.energy_J_total));
            end

            % broken-link hints
            if isfield(ctx.tmp,'debug')
                if isfield(ctx.tmp.debug,'scheduler') && isfield(ctx.tmp.debug.scheduler,'selU_reason')
                    disp("scheduler.selU_reason=" + join(ctx.tmp.debug.scheduler.selU_reason(:).', ","));
                end
            end
        end
    end
end

