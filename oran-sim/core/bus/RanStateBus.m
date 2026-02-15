classdef RanStateBus
%RANSTATEBUS Standard state bus for modular ORAN-SIM
%
% 设计目标：
% - Kernel 只写
% - RIC / xApp 只读
% - 字段语义长期稳定
% - 只新增字段，不破坏旧字段

    methods (Static)

        %% =========================================================
        % INIT
        %% =========================================================
        function state = init(cfg)

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            %% =========================
            % Time
            %% =========================
            state.time = struct();
            state.time.slot = 0;
            state.time.t_s  = 0;

            %% =========================
            % Topology
            %% =========================
            state.topology = struct();
            state.topology.numCell = numCell;
            state.topology.numUE   = numUE;
            state.topology.gNBPos  = zeros(numCell,3);

            %% =========================
            % UE state
            %% =========================
            state.ue = struct();

            % Geometry / association
            state.ue.pos         = zeros(numUE,3);
            state.ue.servingCell = ones(numUE,1);

            % Radio
            state.ue.sinr_dB  = zeros(numUE,1);
            state.ue.rsrp_dBm = -inf(numUE,numCell);

            % PHY feedback
            state.ue.cqi  = zeros(numUE,1);
            state.ue.mcs  = zeros(numUE,1);
            state.ue.bler = zeros(numUE,1);

            % Buffer / traffic
            state.ue.buffer_bits      = zeros(numUE,1);
            state.ue.urgent_pkts      = zeros(numUE,1);
            state.ue.minDeadline_slot = inf(numUE,1);

            % HO interruption observability
            state.ue.hoBlocked = false(numUE,1);

            %% =========================
            % Cell state
            %% =========================
            state.cell = struct();

            state.cell.prbTotal = zeros(numCell,1);
            state.cell.prbUsed  = zeros(numCell,1);
            state.cell.prbUtil  = zeros(numCell,1);

            state.cell.txPower_dBm = zeros(numCell,1);
            state.cell.energy_J    = zeros(numCell,1);
            state.cell.sleepState  = zeros(numCell,1);

            % HO parameters
            state.cell.hoHysteresisBaseline_dB  = zeros(numCell,1);
            state.cell.hoHysteresisEffective_dB = zeros(numCell,1);

            %% =========================
            % Channel
            %% =========================
            state.channel = struct();
            state.channel.interference_dBm = nan(numUE,1);
            state.channel.noise_dBm        = nan(numUE,1);

            %% =========================
            % Events
            %% =========================
            state.events = struct();

            state.events.handover = struct();
            state.events.handover.countTotal = 0;
            state.events.handover.lastUE     = 0;
            state.events.handover.lastFrom   = 0;
            state.events.handover.lastTo     = 0;

            state.events.anomaly = struct();
            state.events.anomaly.flag     = false;
            state.events.anomaly.type     = "";
            state.events.anomaly.severity = 0;
            state.events.anomaly.ueId     = 0;
            state.events.anomaly.cellId   = 0;

            %% =========================
            % KPI (safe exposure)
            %% =========================
            state.kpi = struct();

            state.kpi.throughputBitPerUE = zeros(numUE,1);
            state.kpi.dropTotal          = 0;
            state.kpi.dropURLLC          = 0;
            state.kpi.handoverCount      = 0;
            state.kpi.energyJPerCell     = zeros(numCell,1);
            state.kpi.prbUtilPerCell     = zeros(numCell,1);

        end


        %% =========================================================
        % VALIDATE
        %% =========================================================
        function validate(state, cfg)

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            assert(all(size(state.ue.pos) == [numUE,3]));
            assert(all(size(state.ue.servingCell) == [numUE,1]));
            assert(all(size(state.ue.sinr_dB) == [numUE,1]));
            assert(all(size(state.ue.rsrp_dBm) == [numUE,numCell]));

            assert(all(size(state.cell.prbTotal) == [numCell,1]));
            assert(all(size(state.cell.prbUsed)  == [numCell,1]));
            assert(all(size(state.cell.prbUtil)  == [numCell,1]));

            assert(all(size(state.kpi.throughputBitPerUE) == [numUE,1]));
            assert(all(size(state.kpi.energyJPerCell)     == [numCell,1]));

        end


        %% =========================================================
        % BUILD FROM CONTEXT
        %% =========================================================
        function state = buildFromContext(state, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            %% =========================
            % Time
            %% =========================
            state.time.slot = ctx.slot;
            state.time.t_s  = ctx.slot * ctx.dt;

            %% =========================
            % Topology
            %% =========================
            state.topology.gNBPos = ctx.scenario.topology.gNBPos;

            %% =========================
            % UE state
            %% =========================
            state.ue.pos         = ctx.uePos;
            state.ue.servingCell = ctx.servingCell;
            state.ue.sinr_dB     = ctx.sinr_dB;
            state.ue.rsrp_dBm    = ctx.rsrp_dBm;

            if isfield(ctx.tmp,'lastCQIPerUE')
                state.ue.cqi = ctx.tmp.lastCQIPerUE;
            end
            if isfield(ctx.tmp,'lastMCSPerUE')
                state.ue.mcs = ctx.tmp.lastMCSPerUE;
            end
            if isfield(ctx.tmp,'lastBLERPerUE')
                state.ue.bler = ctx.tmp.lastBLERPerUE;
            end

            % HO interruption observability
            state.ue.hoBlocked = ctx.slot < ctx.ueBlockedUntilSlot;

            %% =========================
            % Traffic
            %% =========================
            qSum = zeros(numUE,1);
            urg  = zeros(numUE,1);
            minDL = inf(numUE,1);

            for u = 1:numUE
                q = ctx.scenario.traffic.model.getQueue(u);
                if isempty(q), continue; end

                qSum(u) = sum([q.size]);

                d = [q.deadline];
                urg(u) = sum(isfinite(d) & d <= 5);

                if any(isfinite(d))
                    minDL(u) = min(d(isfinite(d)));
                end
            end

            state.ue.buffer_bits      = qSum;
            state.ue.urgent_pkts      = urg;
            state.ue.minDeadline_slot = minDL;

            %% =========================
            % Cell
            %% =========================
            state.cell.prbTotal = ctx.numPRB * ones(numCell,1);

            if isfield(ctx.tmp,'lastPRBUsedPerCell')
                state.cell.prbUsed = ctx.tmp.lastPRBUsedPerCell;
            else
                state.cell.prbUsed = zeros(numCell,1);
            end

            state.cell.prbUtil = ...
                state.cell.prbUsed ./ max(state.cell.prbTotal,1);

            state.cell.txPower_dBm = ...
                ctx.txPowerCell_dBm * ones(numCell,1);

            state.cell.energy_J = ctx.accEnergyJPerCell;

            %% =========================
            % Events
            %% =========================
            state.events.handover.countTotal = ctx.accHOCount;

            if isfield(ctx.tmp,'events') && ...
               isfield(ctx.tmp.events,'lastHOue')

                state.events.handover.lastUE   = ctx.tmp.events.lastHOue;
                state.events.handover.lastFrom = ctx.tmp.events.lastHOfrom;
                state.events.handover.lastTo   = ctx.tmp.events.lastHOto;
            end

            %% =========================
            % KPI
            %% =========================
            state.kpi.throughputBitPerUE = ctx.accThroughputBitPerUE;
            state.kpi.dropTotal          = ctx.accDroppedTotal;
            state.kpi.dropURLLC          = ctx.accDroppedURLLC;
            state.kpi.handoverCount      = ctx.accHOCount;
            state.kpi.energyJPerCell     = ctx.accEnergyJPerCell;

            state.kpi.prbUtilPerCell = ...
                ctx.accPRBUsedPerCell ./ ...
                max(ctx.accPRBTotalPerCell,1);

        end
    end
end
