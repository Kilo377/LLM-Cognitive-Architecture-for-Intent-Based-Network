classdef LoadAwareEnergyModel < EnergyModel

    properties
        %% 基础功耗参数
        P0_W              % 静态基站功耗
        k_pa              % 功率放大器系数
        k_load            % PRB 负载系数

        %% HO 额外能耗
        E_ho_J            % 每次 HO 额外能量 (J)

        %% Sleep 模型
        sleepFactor       % 不同 sleep state 的功耗比例
    end

    methods
        function obj = LoadAwareEnergyModel(cfg, scenario)

            obj.P0_W   = scenario.energy.P0;
            obj.k_pa   = scenario.energy.k;

            % 建议参数
            obj.k_load = 80;      % 满负载增加的额外 W

            obj.E_ho_J = 5;       % 每次 HO 消耗 5 J（可调）

            % sleep state:
            % 0 = on
            % 1 = light sleep
            % 2 = deep sleep
            obj.sleepFactor = [1.0, 0.6, 0.15];
        end


        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;

            for c = 1:numCell

                %% ===============================
                % 1. PRB Load
                %% ===============================
                if ctx.numPRB > 0
                    loadRatio = ...
                        ctx.tmp.lastPRBUsedPerCell(c) / ctx.numPRB;
                else
                    loadRatio = 0;
                end

                %% ===============================
                % 2. 基础功耗
                %% ===============================
                P_static = obj.P0_W;

                %% ===============================
                % 3. 发射功率功耗
                %% ===============================
                Ptx_W = 10.^((ctx.txPowerCell_dBm - 30)/10);
                P_pa  = obj.k_pa * Ptx_W;

                %% ===============================
                % 4. 负载相关功耗
                %% ===============================
                P_load = obj.k_load * loadRatio;

                %% ===============================
                % 5. 合成功耗
                %% ===============================
                P_total = P_static + P_pa + P_load;

                %% ===============================
                % 6. Sleep 状态影响
                %% ===============================
                sleepState = 0;

                if isfield(ctx,'action') && ...
                   isfield(ctx.action,'sleep') && ...
                   isfield(ctx.action.sleep,'cellSleepState')

                    sleepState = ctx.action.sleep.cellSleepState(c);
                end

                sleepIdx = min(max(round(sleepState)+1,1),3);
                P_total  = P_total * obj.sleepFactor(sleepIdx);

                %% ===============================
                % 7. 转换为能量
                %% ===============================
                E = P_total * ctx.dt;

                ctx.accEnergyJPerCell(c) = ...
                    ctx.accEnergyJPerCell(c) + E;
            end

            %% ===============================
            % 8. HO 额外能耗（系统级）
            %% ===============================
            if isfield(ctx.tmp,'events') && ...
               isfield(ctx.tmp.events,'lastHOue')

                % 简化：HO 消耗平均分摊给 involved cells
                ctx.accEnergyJPerCell = ...
                    ctx.accEnergyJPerCell + ...
                    obj.E_ho_J / numCell;
            end
        end
    end
end
