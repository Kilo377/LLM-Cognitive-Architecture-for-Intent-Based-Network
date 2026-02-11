classdef RanKernelNR
%RANKERNELNR System-level NR RAN kernel (baseline + action-aware)
%
% 该类是整个 O-RAN 仿真平台的"被控对象"
% - 不包含算法智能
% - 不依赖 xApp
% - 通过 RanActionBus 接收 near-RT 控制
% - 通过 RanStateBus 输出稳定观测
%
% 核心职责：
%   1) slot 级推进仿真时间
%   2) UE 移动、信道测量、业务到达
%   3) 基线 HO 与基线/受控调度
%   4) 调用 NrPhyMacAdapter 得到 PHY-aware 吞吐
%   5) 累积 KPI（吞吐 / 能耗 / HO / 丢包 / PRB）

    properties
        %% ===== 基本对象 =====
        cfg
        scenario
        phyMac              % NrPhyMacAdapter

        %% ===== 时间 =====
        slot                % 当前 slot index
        dt                  % slot duration (s)

        %% ===== UE / Cell 状态 =====
        uePos               % [numUE x 3]
        servingCell         % [numUE x 1]
        rsrp_dBm            % [numUE x numCell]
        sinr_dB             % [numUE x 1]

        %% ===== 调度状态 =====
        rrPtr               % RR pointer per cell

        %% ===== KPI 累积 =====
        accThroughputBitPerUE
        accPRBUsedPerCell
        accPRBTotalPerCell
        accHOCount
        accDroppedTotal
        accDroppedURLLC
        accEnergyJPerCell

        %% ===== 无线与能耗参数 =====
        numPRB
        txPowerCell_dBm
        bandwidthHz
        P0_W
        k_pa

        %% ===== HO 参数 =====
        hoHysteresis_dB
        hoTTT_slot
        hoTimer

        %% ===== 本 slot 临时量（state bus 用）=====
        lastServedUEPerCell     % [numCell x 1]
        lastMCSPerUE            % [numUE x 1]
        lastCQIPerUE            % [numUE x 1]
        lastBLERPerUE           % [numUE x 1]
        lastPRBUsedPerCell      % [numCell x 1]

        %% ===== 状态总线 =====
        state                  % RanStateBus struct
    end

    methods
        %% =========================================================
        % 构造函数
        %% =========================================================
        function obj = RanKernelNR(cfg, scenario)

            obj.cfg      = cfg;
            obj.scenario = scenario;

            obj.slot = 0;
            obj.dt   = cfg.sim.slotDuration;

            obj.state = RanStateBus.init(cfg);

            numUE   = cfg.scenario.numUE;
            numCell = cfg.scenario.numCell;

            %% UE / Cell 初始状态
            obj.uePos       = scenario.topology.ueInitPos;
            obj.servingCell = ones(numUE,1);
            obj.rrPtr       = ones(numCell,1);

            %% KPI 累积
            obj.accThroughputBitPerUE = zeros(numUE,1);
            obj.accPRBUsedPerCell     = zeros(numCell,1);
            obj.accPRBTotalPerCell    = zeros(numCell,1);
            obj.accHOCount            = 0;
            obj.accDroppedTotal       = 0;
            obj.accDroppedURLLC       = 0;
            obj.accEnergyJPerCell     = zeros(numCell,1);

            %% 无线参数
            obj.bandwidthHz     = scenario.radio.bandwidth;
            obj.numPRB          = 106; % 20 MHz @ 30 kHz SCS（近似）
            obj.txPowerCell_dBm = scenario.radio.txPower.cell;

            %% 能耗模型
            obj.P0_W = scenario.energy.P0;
            obj.k_pa = scenario.energy.k;

            %% HO 参数
            obj.hoHysteresis_dB = 3;
            obj.hoTTT_slot      = 5;
            obj.hoTimer         = zeros(numUE,1);

            %% slot 临时量
            obj.lastServedUEPerCell = zeros(numCell,1);
            obj.lastMCSPerUE        = zeros(numUE,1);
            obj.lastCQIPerUE        = zeros(numUE,1);
            obj.lastBLERPerUE       = zeros(numUE,1);
            obj.lastPRBUsedPerCell  = zeros(numCell,1);

            %% PHY/MAC adapter
            obj.phyMac = NrPhyMacAdapter(cfg, scenario);

            %% 初始测量与关联
            obj = obj.updateRadioMeasurements();
            obj = obj.initialAssociation();
            obj = obj.updateStateBus();
        end

        %% =========================================================
        % baseline slot 推进
        %% =========================================================
        function obj = stepBaseline(obj)

            obj.slot = obj.slot + 1;
            obj = obj.clearSlotTemp();

            %% UE 移动
            [obj.scenario.mobility.model, pos2d] = ...
                obj.scenario.mobility.model.step(obj.dt);
            obj.uePos(:,1:2) = pos2d;

            %% 业务到达 + 截止时间
            obj.scenario.traffic.model = obj.scenario.traffic.model.step();
            obj.scenario.traffic.model = obj.scenario.traffic.model.decreaseDeadline();
            [obj.scenario.traffic.model, dropped] = ...
                obj.scenario.traffic.model.dropExpired();
            obj = obj.accountDrops(dropped);

            %% 无线测量 + HO
            obj = obj.updateRadioMeasurements();
            obj = obj.handoverBaseline();

            %% 调度 + PHY/MAC
            obj = obj.scheduleAndServeBaseline();

            %% 能耗 + 状态
            obj = obj.updateEnergyBaseline();
            obj = obj.updateStateBus();
        end

        %% =========================================================
        % RIC / xApp slot 推进（action-aware）
        %% =========================================================
        function obj = stepWithAction(obj, action)

            obj.slot = obj.slot + 1;
            obj = obj.clearSlotTemp();

            %% UE 移动
            [obj.scenario.mobility.model, pos2d] = ...
                obj.scenario.mobility.model.step(obj.dt);
            obj.uePos(:,1:2) = pos2d;

            %% 业务到达 + 丢包
            obj.scenario.traffic.model = obj.scenario.traffic.model.step();
            obj.scenario.traffic.model = obj.scenario.traffic.model.decreaseDeadline();
            [obj.scenario.traffic.model, dropped] = ...
                obj.scenario.traffic.model.dropExpired();
            obj = obj.accountDrops(dropped);

            %% 无线测量 + HO
            obj = obj.updateRadioMeasurements();
            obj = obj.handoverBaseline();

            %% action-aware 调度
            obj = obj.scheduleAndServeWithAction(action);

            %% 能耗 + 状态
            obj = obj.updateEnergyBaseline();
            obj = obj.updateStateBus();
        end

        %% =========================================================
        % 对外接口
        %% =========================================================
        function state = getState(obj)
            state = obj.state;
        end

        function report = finalize(obj)
            T = obj.cfg.sim.slotPerEpisode * obj.dt;
            report.throughput_bps_total = sum(obj.accThroughputBitPerUE) / T;
            report.prb_util_perCell     = obj.accPRBUsedPerCell ./ max(obj.accPRBTotalPerCell,1);
            report.handover_count       = obj.accHOCount;
            report.dropped_total        = obj.accDroppedTotal;
            report.dropped_urllc        = obj.accDroppedURLLC;
            report.energy_J_total       = sum(obj.accEnergyJPerCell);
            report.energy_eff_bit_per_J = ...
                sum(obj.accThroughputBitPerUE) / max(report.energy_J_total,1e-9);
        end
    end

    methods (Access = private)
        %% =========================================================
        % slot 临时量清空
        %% =========================================================
        function obj = clearSlotTemp(obj)
            obj.lastServedUEPerCell(:) = 0;
            obj.lastPRBUsedPerCell(:)  = 0;
            obj.lastCQIPerUE(:)  = 0;
            obj.lastMCSPerUE(:)  = 0;
            obj.lastBLERPerUE(:) = 0;
        end

        %% =========================================================
        % 初始小区选择
        %% =========================================================
        function obj = initialAssociation(obj)
            [~, best] = max(obj.rsrp_dBm, [], 2);
            obj.servingCell = best;
        end

        %% =========================================================
        % RSRP + SINR（简化）
        %% =========================================================
        function obj = updateRadioMeasurements(obj)

            numUE   = obj.cfg.scenario.numUE;
            numCell = obj.cfg.scenario.numCell;
            gNB     = obj.scenario.topology.gNBPos;

            rsrp = zeros(numUE, numCell);

            for c = 1:numCell
                d = vecnorm(obj.uePos - gNB(c,:), 2, 2);
                d = max(d,1);
                pl_dB = 10*3.5*log10(d) + 4*randn(numUE,1);
                rsrp(:,c) = obj.txPowerCell_dBm - pl_dB;
            end
            obj.rsrp_dBm = rsrp;

            sinr = zeros(numUE,1);
            for u = 1:numUE
                s = obj.servingCell(u);
                sig = 10^(rsrp(u,s)/10);
                int = sum(10.^(rsrp(u,[1:s-1,s+1:end])/10));
                sinr(u) = 10*log10(sig/(int+1e-12));
            end
            obj.sinr_dB = sinr;
        end

        %% =========================================================
        % 基线 HO（A3 + TTT）
        %% =========================================================
        function obj = handoverBaseline(obj)
            for u = 1:obj.cfg.scenario.numUE
                s = obj.servingCell(u);
                [bestRSRP, bestCell] = max(obj.rsrp_dBm(u,:));
                if bestCell ~= s && ...
                   bestRSRP - obj.rsrp_dBm(u,s) >= obj.hoHysteresis_dB
                    obj.hoTimer(u) = obj.hoTimer(u) + 1;
                    if obj.hoTimer(u) >= obj.hoTTT_slot
                        obj.servingCell(u) = bestCell;
                        obj.hoTimer(u) = 0;
                        obj.accHOCount = obj.accHOCount + 1;
                    end
                else
                    obj.hoTimer(u) = 0;
                end
            end
        end

        %% =========================================================
        % baseline 调度
        %% =========================================================
        function obj = scheduleAndServeBaseline(obj)

            numCell = obj.cfg.scenario.numCell;

            for c = 1:numCell
                ueSet = find(obj.servingCell == c);
                obj.accPRBTotalPerCell(c) = obj.accPRBTotalPerCell(c) + obj.numPRB;
                if isempty(ueSet), continue; end

                k = mod(obj.rrPtr(c)-1, numel(ueSet)) + 1;
                u = ueSet(k);
                obj.rrPtr(c) = obj.rrPtr(c) + 1;

                obj.lastServedUEPerCell(c) = u;

                obj = obj.serveOneUE(c, u);
            end
        end

        %% =========================================================
        % action-aware 调度
        %% =========================================================
        function obj = scheduleAndServeWithAction(obj, action)

            numCell = obj.cfg.scenario.numCell;

            if isempty(action) || ~isfield(action,'scheduling')
                obj = obj.scheduleAndServeBaseline();
                return;
            end

            sel = action.scheduling.selectedUE;

            for c = 1:numCell
                ueSet = find(obj.servingCell == c);
                obj.accPRBTotalPerCell(c) = obj.accPRBTotalPerCell(c) + obj.numPRB;
                if isempty(ueSet), continue; end

                u = 0;
                if numel(sel) >= c && sel(c) > 0 && any(ueSet == sel(c))
                    u = sel(c);
                end
                if u == 0
                    k = mod(obj.rrPtr(c)-1, numel(ueSet)) + 1;
                    u = ueSet(k);
                    obj.rrPtr(c) = obj.rrPtr(c) + 1;
                end

                obj.lastServedUEPerCell(c) = u;
                obj = obj.serveOneUE(c, u);
            end
        end

        %% =========================================================
        % 单 UE 服务（PHY/MAC + queue）
        %% =========================================================
        function obj = serveOneUE(obj, c, u)

            schedInfo.ueId   = u;
            schedInfo.numPRB = obj.numPRB;
            schedInfo.mcs    = [];

            radioMeas.sinr_dB = obj.sinr_dB(u);

            obj.phyMac = obj.phyMac.step(schedInfo, radioMeas);
            bits = obj.phyMac.getServedBits(u);

            obj.lastBLERPerUE(u) = obj.phyMac.lastBLER(u);
            obj.lastCQIPerUE(u)  = obj.sinrToCQIApprox(obj.sinr_dB(u));
            obj.lastMCSPerUE(u)  = max(obj.lastCQIPerUE(u)-1,0);

            [obj.scenario.traffic.model, served] = ...
                obj.scenario.traffic.model.serve(u, bits);

            obj.accThroughputBitPerUE(u) = obj.accThroughputBitPerUE(u) + served;

            if served > 0
                obj.accPRBUsedPerCell(c) = obj.accPRBUsedPerCell(c) + obj.numPRB;
                obj.lastPRBUsedPerCell(c) = obj.numPRB;
            end
        end

        %% =========================================================
        % 能耗
        %% =========================================================
        function obj = updateEnergyBaseline(obj)
            Ptx_W = 10.^((obj.txPowerCell_dBm-30)/10);
            P = obj.P0_W + obj.k_pa * Ptx_W;
            obj.accEnergyJPerCell = obj.accEnergyJPerCell + P * obj.dt;
        end

        %% =========================================================
        % 丢包统计
        %% =========================================================
        function obj = accountDrops(obj, dropped)
            if isempty(dropped), return; end
            obj.accDroppedTotal = obj.accDroppedTotal + numel(dropped);
            for i = 1:numel(dropped)
                if strcmp(dropped(i).type,'URLLC')
                    obj.accDroppedURLLC = obj.accDroppedURLLC + 1;
                end
            end
        end

        %% =========================================================
        % 状态总线
        %% =========================================================
        function obj = updateStateBus(obj)

            numUE   = obj.cfg.scenario.numUE;
            numCell = obj.cfg.scenario.numCell;

            s = obj.state;

            s.time.slot = obj.slot;
            s.time.t_s  = obj.slot * obj.dt;

            s.topology.numUE   = numUE;
            s.topology.numCell = numCell;
            s.topology.gNBPos  = obj.scenario.topology.gNBPos;

            s.ue.pos         = obj.uePos;
            s.ue.servingCell = obj.servingCell;
            s.ue.sinr_dB     = obj.sinr_dB;
            s.ue.rsrp_dBm    = obj.rsrp_dBm;
            s.ue.cqi         = obj.lastCQIPerUE;
            s.ue.mcs         = obj.lastMCSPerUE;
            s.ue.bler        = obj.lastBLERPerUE;

            qSum = zeros(numUE,1);
            urg  = zeros(numUE,1);
            minDL = inf(numUE,1);   % inf 表示该 UE 当前没有 deadline 包

            for u = 1:numUE
                q = obj.scenario.traffic.model.getQueue(u);
                if isempty(q)
                    continue;
                end
            
                % buffer 总量
                qSum(u) = sum([q.size]);
            
                % deadline 向量（单位：slot）
                d = [q.deadline];
            
                % urgent 计数（保持你原来的定义）
                urg(u) = sum(isfinite(d) & d <= 5);
            
                % 最小 deadline（EDF 关键输入）
                if any(isfinite(d))
                    minDL(u) = min(d(isfinite(d)));
                end
            end
            s.ue.buffer_bits = qSum;
            s.ue.urgent_pkts = urg;
            s.ue.minDeadline_slot = minDL;  % 新增字段

            s.cell.prbTotal = obj.numPRB * ones(numCell,1);
            s.cell.prbUsed  = obj.lastPRBUsedPerCell;
            s.cell.prbUtil  = s.cell.prbUsed ./ max(s.cell.prbTotal,1);
            s.cell.txPower_dBm = obj.txPowerCell_dBm * ones(numCell,1);
            s.cell.energy_J    = obj.accEnergyJPerCell;
            s.cell.sleepState  = zeros(numCell,1);

            s.kpi.throughputBitPerUE = obj.accThroughputBitPerUE;
            s.kpi.dropTotal          = obj.accDroppedTotal;
            s.kpi.dropURLLC          = obj.accDroppedURLLC;
            s.kpi.handoverCount      = obj.accHOCount;
            s.kpi.energyJPerCell     = obj.accEnergyJPerCell;
            s.kpi.prbUtilPerCell     = ...
                obj.accPRBUsedPerCell ./ max(obj.accPRBTotalPerCell,1);

            obj.state = s;
        end

        %% =========================================================
        % SINR -> CQI 近似
        %% =========================================================
        function cqi = sinrToCQIApprox(~, sinr_dB)
            th = [-5 -2 1 3 5 7 9 11 13 15 17 19 21 23 25];
            cqi = find(sinr_dB < th,1)-1;
            if isempty(cqi), cqi = 15; end
            cqi = max(min(cqi,15),1);
        end
    end
end
