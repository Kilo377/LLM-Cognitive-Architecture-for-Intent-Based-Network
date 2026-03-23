%{
Author: Chongyu Bao (zt25108@bristol.ac.uk)
File: UEMobilityModel.m
Description:
Random Waypoint mobility model with hotspot and edge-biased UE distribution.
Compatible with initPos input.
%}

classdef UEMobilityModel

    properties
        %% Basic
        numUE

        %% Dynamic state
        pos
        speed
        targetPos

        baseSpeed
        slotNow

        %% Area
        areaX
        areaY

        %% Speed config
        speedMin
        speedMax
        highSpeedRatio

        %% Pause control
        pauseTime
        pauseTimer

        %% ===== New distribution control =====
        hotspotRatio = 0.6
        edgeRatio    = 0.3
        hotspotSigma = 40

        %% ===== dynamics =====
        dynamics

        %% ===== trend =====
        trend
        edgeBias = 0
        lastTrend
        lastDynamic
    end

    methods

        %% =========================================================
        % Constructor
        %% =========================================================
        function obj = UEMobilityModel(varargin)

            p = inputParser;

            addParameter(p,'numUE',10);
            addParameter(p,'initPos',[]);   % compatibility
            addParameter(p,'areaX',[-300 300]);
            addParameter(p,'areaY',[-300 300]);
            addParameter(p,'speedRange',[1 25]);
            addParameter(p,'highSpeedRatio',0.3);
            addParameter(p,'pauseTime',0);
            addParameter(p,'dynamicCfg',struct());
            addParameter(p,'trendCfg',struct());

            parse(p,varargin{:});

            obj.numUE = p.Results.numUE;
            obj.areaX = p.Results.areaX;
            obj.areaY = p.Results.areaY;

            %% =====================================================
            % Position initialization
            %% =====================================================
            if ~isempty(p.Results.initPos)

                obj.pos = p.Results.initPos(:,1:2);

            else

                hotspotCenter = [
                    -150 -150;
                     150 -150;
                    -150  150;
                     150  150
                ];

                numHotUE  = round(obj.numUE * obj.hotspotRatio);
                numEdgeUE = round(obj.numUE * obj.edgeRatio);
                numRandUE = obj.numUE - numHotUE - numEdgeUE;

                pos = zeros(obj.numUE,2);
                idx = randperm(obj.numUE);

                %% -----------------------------
                % Hotspot UE
                %% -----------------------------
                for i = 1:numHotUE
                    h = hotspotCenter(randi(size(hotspotCenter,1)),:);
                    pos(idx(i),:) = h + obj.hotspotSigma * randn(1,2);
                end

                %% -----------------------------
                % Edge-biased UE
                %% -----------------------------
                R = min(diff(obj.areaX), diff(obj.areaY)) / 2;
                cx = mean(obj.areaX);
                cy = mean(obj.areaY);

                for i = 1:numEdgeUE
                    id = idx(numHotUE+i);

                    theta = 2*pi*rand;
                    r = 0.8*R + 0.2*R*rand;

                    pos(id,1) = cx + r*cos(theta);
                    pos(id,2) = cy + r*sin(theta);
                end

                %% -----------------------------
                % Uniform random UE
                %% -----------------------------
                for i = 1:numRandUE
                    id = idx(numHotUE+numEdgeUE+i);
                    pos(id,1) = rand*(diff(obj.areaX))+obj.areaX(1);
                    pos(id,2) = rand*(diff(obj.areaY))+obj.areaY(1);
                end

                obj.pos = pos;
            end

            %% =====================================================
            % Speed initialization
            %% =====================================================
            obj.speed = zeros(obj.numUE,1);

            for i = 1:obj.numUE
                if rand < p.Results.highSpeedRatio
                    obj.speed(i) = 20 + 5*rand;
                else
                    obj.speed(i) = 1 + 2*rand;
                end
            end

            obj.targetPos = obj.generateRandomTarget(obj.numUE);

            obj.pauseTime  = p.Results.pauseTime;
            obj.pauseTimer = zeros(obj.numUE,1);

            obj.baseSpeed = obj.speed;
            obj.slotNow = 0;

            dynCfg = p.Results.dynamicCfg;
            if isstruct(dynCfg) && isfield(dynCfg,'enable') && dynCfg.enable
                if ~isfield(dynCfg,'profiles')
                    obj.dynamics = MobilityDynamics(dynCfg);
                else
                    try
                        ps = string(dynCfg.profiles);
                        if any(ps == "mobility")
                            obj.dynamics = MobilityDynamics(dynCfg);
                        end
                    catch
                    end
                end
            end

            trendCfg = p.Results.trendCfg;
            if isstruct(trendCfg) && isfield(trendCfg,'enable') && trendCfg.enable
                obj.trend = MobilityTrend(trendCfg);
            end
        end


        %% =========================================================
        % Generate random target
        %% =========================================================
        function target = generateRandomTarget(obj, n, edgeBias)

            if nargin < 2
                n = obj.numUE;
            end
            if nargin < 3
                edgeBias = 0;
            end

            target = zeros(n,2);

            R = min(diff(obj.areaX), diff(obj.areaY)) / 2;
            cx = mean(obj.areaX);
            cy = mean(obj.areaY);

            for i = 1:n
                if rand < edgeBias
                    theta = 2*pi*rand;
                    r = (0.8 + 0.2*rand) * R;
                    target(i,1) = cx + r*cos(theta);
                    target(i,2) = cy + r*sin(theta);
                else
                    target(i,1) = rand*(diff(obj.areaX))+obj.areaX(1);
                    target(i,2) = rand*(diff(obj.areaY))+obj.areaY(1);
                end
            end
        end


        %% =========================================================
        % Step update
        %% =========================================================
        function [obj,pos] = step(obj,deltaT)
            obj.slotNow = obj.slotNow + 1;

            obj = obj.applyTrend();

            speedScale = 1.0;
            directionJitter = 0.0;
            pauseProb = 0.0;
            if ~isempty(obj.dynamics)
                dyn = obj.dynamics.get(obj.slotNow);
                speedScale = dyn.speedScale;
                directionJitter = dyn.directionJitter;
                pauseProb = dyn.pauseProbability;
            end

            obj.lastDynamic = struct('speedScale', speedScale, ...
                'directionJitter', directionJitter, ...
                'pauseProbability', pauseProb);

            obj.speed = obj.baseSpeed * speedScale;

            for i = 1:obj.numUE

                if obj.pauseTimer(i) > 0
                    obj.pauseTimer(i) = obj.pauseTimer(i) - deltaT;
                    continue;
                end

                if obj.pauseTime > 0 && pauseProb > 0
                    if rand < pauseProb
                        obj.pauseTimer(i) = obj.pauseTime;
                        continue;
                    end
                end

                if obj.edgeBias > 0 && rand < 0.02 * obj.edgeBias
                    obj.targetPos(i,:) = obj.generateRandomTarget(1, obj.edgeBias);
                end

                dx = obj.targetPos(i,1) - obj.pos(i,1);
                dy = obj.targetPos(i,2) - obj.pos(i,2);

                dist = sqrt(dx^2 + dy^2);

                if dist < obj.speed(i)*deltaT

                    obj.pos(i,:) = obj.targetPos(i,:);
                    obj.targetPos(i,:) = obj.generateRandomTarget(1, obj.edgeBias);
                    obj.pauseTimer(i) = obj.pauseTime;

                else

                    dirX = dx / dist;
                    dirY = dy / dist;

                    if directionJitter > 0
                        jitterAngle = (rand - 0.5) * 2 * directionJitter;
                        c = cos(jitterAngle);
                        s = sin(jitterAngle);
                        jx = dirX * c - dirY * s;
                        jy = dirX * s + dirY * c;
                        dirX = jx;
                        dirY = jy;
                    end

                    obj.pos(i,1) = obj.pos(i,1) + obj.speed(i)*dirX*deltaT;
                    obj.pos(i,2) = obj.pos(i,2) + obj.speed(i)*dirY*deltaT;
                end
            end

            pos = obj.pos;
        end


        %% =========================================================
        % Export state
        %% =========================================================
        function state = getState(obj)
            state.pos   = obj.pos;
            state.speed = obj.speed;
        end
    end

    methods (Access=private)
        function obj = applyTrend(obj)
            if isempty(obj.trend)
                obj.edgeBias = 0;
                return;
            end

            tr = obj.trend.get(obj.slotNow);
            obj.lastTrend = tr;
            obj.edgeBias = tr.edgeBias;
        end
    end
end
