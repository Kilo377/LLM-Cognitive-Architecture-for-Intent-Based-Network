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
        end


        %% =========================================================
        % Generate random target
        %% =========================================================
        function target = generateRandomTarget(obj,n)

            if nargin < 2
                n = obj.numUE;
            end

            target = [ ...
                rand(n,1)*(diff(obj.areaX))+obj.areaX(1), ...
                rand(n,1)*(diff(obj.areaY))+obj.areaY(1)];
        end


        %% =========================================================
        % Step update
        %% =========================================================
        function [obj,pos] = step(obj,deltaT)

            for i = 1:obj.numUE

                if obj.pauseTimer(i) > 0
                    obj.pauseTimer(i) = obj.pauseTimer(i) - deltaT;
                    continue;
                end

                dx = obj.targetPos(i,1) - obj.pos(i,1);
                dy = obj.targetPos(i,2) - obj.pos(i,2);

                dist = sqrt(dx^2 + dy^2);

                if dist < obj.speed(i)*deltaT

                    obj.pos(i,:) = obj.targetPos(i,:);
                    obj.targetPos(i,:) = obj.generateRandomTarget(1);
                    obj.pauseTimer(i) = obj.pauseTime;

                else

                    dirX = dx / dist;
                    dirY = dy / dist;

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
end