classdef UEMobilityModel
%UEMOBILITYMODEL Random Waypoint UE mobility model
%
%   功能：
%   实现经典 Random Waypoint (RWP) 移动模型。
%   适用于小区切换、移动性优化、handover xApp 验证。
%
%   特点：
%   - UE 在给定区域内随机选择目标点
%   - 直线移动到目标点
%   - 到达后可暂停
%   - 支持高速 / 低速 UE 分层
%   - 支持固定随机种子复现实验
%
%   状态输出：
%   - UE 位置
%   - UE 速度
%
%   适合：
%   - mobility-aware xApp
%   - handover KPI 评估
%   - 统计型对比实验

    properties
        %% 基本属性
        numUE              % UE 数量

        %% 动态状态
        pos                % UE 位置 [numUE x 2]
        speed              % UE 速度 [numUE x 1]
        targetPos          % 当前目标点 [numUE x 2]

        %% 场景边界
        areaX              % x 轴边界 [xmin xmax]
        areaY              % y 轴边界 [ymin ymax]

        %% 速度配置
        speedMin
        speedMax
        highSpeedRatio     % 高速 UE 比例

        %% 停顿控制
        pauseTime          % 到达目标后的暂停时间
        pauseTimer         % 当前剩余暂停时间
    end

    methods

        %% ===============================
        % 构造函数
        %% ===============================
        function obj = UEMobilityModel(varargin)

            p = inputParser;

            addParameter(p,'numUE',10);
            addParameter(p,'initPos',[]);
            addParameter(p,'areaX',[-300 300]);
            addParameter(p,'areaY',[-300 300]);
            addParameter(p,'speedRange',[1 25]);
            addParameter(p,'highSpeedRatio',0.3);
            addParameter(p,'pauseTime',0);

            parse(p,varargin{:});

            obj.numUE = p.Results.numUE;

            obj.areaX = p.Results.areaX;
            obj.areaY = p.Results.areaY;

            %% 初始化位置
            if isempty(p.Results.initPos)
                obj.pos = [ ...
                    rand(obj.numUE,1)*(diff(obj.areaX))+obj.areaX(1), ...
                    rand(obj.numUE,1)*(diff(obj.areaY))+obj.areaY(1)];
            else
                obj.pos = p.Results.initPos(:,1:2);
            end

            %% 速度范围
            obj.speedMin = p.Results.speedRange(1);
            obj.speedMax = p.Results.speedRange(2);

            %% 速度分层初始化
            obj.speed = zeros(obj.numUE,1);
            for i = 1:obj.numUE
                if rand < p.Results.highSpeedRatio
                    % 高速 UE（例如车载）
                    obj.speed(i) = 20 + 5*rand;  % 20–25 m/s
                else
                    % 低速 UE（例如行人）
                    obj.speed(i) = 1 + 2*rand;   % 1–3 m/s
                end
            end

            %% 初始目标点
            obj.targetPos = obj.generateRandomTarget(obj.numUE);

            %% 停顿控制
            obj.pauseTime  = p.Results.pauseTime;
            obj.pauseTimer = zeros(obj.numUE,1);
        end


        %% ===============================
        % 生成随机目标点
        %% ===============================
        function target = generateRandomTarget(obj,n)

            if nargin < 2
                n = obj.numUE;
            end

            target = [ ...
                rand(n,1)*(diff(obj.areaX))+obj.areaX(1), ...
                rand(n,1)*(diff(obj.areaY))+obj.areaY(1)];
        end


        %% ===============================
        % 单步更新
        %% ===============================
        function [obj,pos] = step(obj,deltaT)
        % deltaT: 时间步长（秒）

            for i = 1:obj.numUE

                % 若处于暂停状态
                if obj.pauseTimer(i) > 0
                    obj.pauseTimer(i) = obj.pauseTimer(i) - deltaT;
                    continue;
                end

                % 计算目标方向
                dx = obj.targetPos(i,1) - obj.pos(i,1);
                dy = obj.targetPos(i,2) - obj.pos(i,2);

                dist = sqrt(dx^2 + dy^2);

                % 若接近目标点
                if dist < obj.speed(i)*deltaT

                    % 到达目标
                    obj.pos(i,:) = obj.targetPos(i,:);

                    % 生成新的目标点
                    newTarget = obj.generateRandomTarget(1);
                    obj.targetPos(i,:) = newTarget;

                    % 设置暂停
                    obj.pauseTimer(i) = obj.pauseTime;

                else
                    % 单位方向向量
                    dirX = dx / dist;
                    dirY = dy / dist;

                    % 更新位置
                    obj.pos(i,1) = obj.pos(i,1) + obj.speed(i)*dirX*deltaT;
                    obj.pos(i,2) = obj.pos(i,2) + obj.speed(i)*dirY*deltaT;
                end
            end

            pos = obj.pos;
        end


        %% ===============================
        % 导出当前状态
        %% ===============================
        function state = getState(obj)

            state.pos   = obj.pos;
            state.speed = obj.speed;

        end
    end
end
