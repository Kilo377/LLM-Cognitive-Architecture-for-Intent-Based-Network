classdef UEMobilityModel
%UEMOBILITYMODEL Simple trend-based UE mobility model
%   Position evolves with continuous velocity and direction
%   Suitable for mobility prediction and LSTM learning

    properties
        numUE

        % State
        pos        % [numUE x 2]
        speed      % [numUE x 1]
        direction  % [numUE x 1] (radian)

        % Parameters
        speedMin
        speedMax
        dirStd
        speedStd
        posNoiseStd
    end

    methods
        function obj = UEMobilityModel(varargin)
            % Parse inputs
            p = inputParser;
            addParameter(p, 'numUE', 10);
            addParameter(p, 'initPos', []);
            addParameter(p, 'speedRange', [0.5, 1.5]);  % m/s
            addParameter(p, 'dirStd', 0.05);            % rad
            addParameter(p, 'speedStd', 0.05);          % m/s
            addParameter(p, 'posNoiseStd', 0.1);        % m
            parse(p, varargin{:});

            obj.numUE = p.Results.numUE;

            % Init position
            if isempty(p.Results.initPos)
                obj.pos = zeros(obj.numUE, 2);
            else
                obj.pos = p.Results.initPos(:,1:2);
            end

            % Init velocity state
            obj.speedMin = p.Results.speedRange(1);
            obj.speedMax = p.Results.speedRange(2);

            obj.speed = obj.speedMin + ...
                (obj.speedMax - obj.speedMin) * rand(obj.numUE,1);

            obj.direction = 2*pi*rand(obj.numUE,1);

            % Noise parameters
            obj.dirStd      = p.Results.dirStd;
            obj.speedStd    = p.Results.speedStd;
            obj.posNoiseStd = p.Results.posNoiseStd;
        end

        function [obj, pos] = step(obj, deltaT)
            %STEP Update UE positions
            %   deltaT: slot duration in seconds

            % Direction drift
            obj.direction = obj.direction + ...
                obj.dirStd * randn(obj.numUE,1);

            % Speed fluctuation
            obj.speed = obj.speed + ...
                obj.speedStd * randn(obj.numUE,1);

            % Clip speed
            obj.speed = min(max(obj.speed, obj.speedMin), obj.speedMax);

            % Position update
            dx = obj.speed .* cos(obj.direction) * deltaT;
            dy = obj.speed .* sin(obj.direction) * deltaT;

            obj.pos(:,1) = obj.pos(:,1) + dx + ...
                obj.posNoiseStd * randn(obj.numUE,1);
            obj.pos(:,2) = obj.pos(:,2) + dy + ...
                obj.posNoiseStd * randn(obj.numUE,1);

            pos = obj.pos;
        end

        function state = getState(obj)
            %GETSTATE Export mobility state (for learning/logging)
            state.pos       = obj.pos;
            state.speed     = obj.speed;
            state.direction = obj.direction;
        end
    end
end
