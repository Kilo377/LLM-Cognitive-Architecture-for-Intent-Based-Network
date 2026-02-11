classdef RanActionBus
%RANACTIONBUS Standard action bus for ORAN-SIM (Finalized Version)
%
% ========================= 角色定位 =========================
%
% RanActionBus 是 near-RT RIC 与 RanKernelNR 之间的
% "唯一、稳定、强约束"的动作接口。
%
% - xApp           ：不能直接写 RanActionBus
% - xApp           ：只输出 action.control.{key}
% - near-RT RIC    ：负责 control -> RanActionBus 的语义映射
% - ActionGuard    ：调用 validate 做安全裁剪
% - RanKernelNR    ：只读取 RanActionBus，不做任何校验
%
% ========================= 设计原则 =========================
%
% 1. 所有字段都有 baseline 回退语义
% 2. 所有向量长度都由 cfg.scenario 决定
% 3. validate 是唯一合法性检查入口
% 4. 新控制域只允许"加字段"，不允许改语义
%
% ===========================================================

    methods (Static)

        function action = init(cfg)
            %INIT Initialize an empty action bus with safe defaults
            %
            % 所有字段初始化为"无控制"状态
            % kernel 在检测到无控制值时自动走 baseline

            numCell = cfg.scenario.numCell;
            numUE   = cfg.scenario.numUE;

            action = struct();

            %% ==================================================
            % Scheduling control (near-RT)
            %% ==================================================
            % 每小区选择一个 UE
            % selectedUE(c) = u
            %   u = 0  : 不干预，kernel 使用 baseline 调度
            %   u > 0  : 指定 UE 索引
            action.scheduling = struct();
            action.scheduling.selectedUE = zeros(numCell,1);

            %% ==================================================
            % Power control (reserved)
            %% ==================================================
            % 小区发射功率相对偏置（dB）
            % 正值：升功率
            % 负值：降功率
            action.power = struct();
            action.power.cellTxPowerOffset_dB = zeros(numCell,1);

            %% ==================================================
            % Cell sleep control (reserved)
            %% ==================================================
            % 每小区睡眠状态
            % 0 : on
            % 1 : light sleep
            % 2 : deep sleep
            action.sleep = struct();
            action.sleep.cellSleepState = zeros(numCell,1);

            %% ==================================================
            % Handover control (reserved)
            %% ==================================================
            % 小区级切换滞回参数偏置（dB）
            % 正值：延迟切换
            % 负值：提前切换
            action.handover = struct();
            action.handover.hysteresisOffset_dB = zeros(numCell,1);

            %% ==================================================
            % Beamforming control (reserved)
            %% ==================================================
            % UE 级波束选择
            % ueBeamId(u) = b
            %   b = 0 : 不控制
            %   b > 0 : 指定波束索引
            action.beam = struct();
            action.beam.ueBeamId = zeros(numUE,1);
        end

        function action = validate(action, cfg, state)
            %VALIDATE Sanity check and clip action into valid range
            %
            % 该函数只在 near-RT RIC 内部调用
            % kernel 假设输入 action 已经是合法的
            %
            % validate 只做三件事：
            % 1. 维度检查
            % 2. 数值裁剪
            % 3. 物理一致性检查

            numCell = cfg.scenario.numCell;
            numUE   = cfg.scenario.numUE;

            %% ==================================================
            % Scheduling validation
            %% ==================================================
            sel = action.scheduling.selectedUE;

            if ~isvector(sel) || numel(sel) ~= numCell
                action.scheduling.selectedUE = zeros(numCell,1);
            else
                sel = round(sel(:));
                sel(sel < 0) = 0;
                sel(sel > numUE) = 0;

                % 必须是该小区的 serving UE
                for c = 1:numCell
                    u = sel(c);
                    if u == 0
                        continue;
                    end
                    if state.ue.servingCell(u) ~= c
                        sel(c) = 0;
                    end
                end

                action.scheduling.selectedUE = sel;
            end

            %% ==================================================
            % Power control validation
            %% ==================================================
            p = action.power.cellTxPowerOffset_dB;

            if numel(p) ~= numCell
                action.power.cellTxPowerOffset_dB = zeros(numCell,1);
            else
                action.power.cellTxPowerOffset_dB = ...
                    max(min(p(:), 10), -10);
            end

            %% ==================================================
            % Sleep control validation
            %% ==================================================
            s = action.sleep.cellSleepState;

            if numel(s) ~= numCell
                action.sleep.cellSleepState = zeros(numCell,1);
            else
                s = round(s(:));
                s(s < 0) = 0;
                s(s > 2) = 2;
                action.sleep.cellSleepState = s;
            end

            %% ==================================================
            % Handover control validation
            %% ==================================================
            h = action.handover.hysteresisOffset_dB;

            if numel(h) ~= numCell
                action.handover.hysteresisOffset_dB = zeros(numCell,1);
            else
                action.handover.hysteresisOffset_dB = ...
                    max(min(h(:), 5), -5);
            end

            %% ==================================================
            % Beamforming control validation
            %% ==================================================
            b = action.beam.ueBeamId;

            if numel(b) ~= numUE
                action.beam.ueBeamId = zeros(numUE,1);
            else
                b = round(b(:));
                b(b < 0) = 0;
                action.beam.ueBeamId = b;
            end
        end
    end
end
