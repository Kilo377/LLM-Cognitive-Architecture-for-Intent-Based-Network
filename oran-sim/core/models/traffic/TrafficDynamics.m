classdef TrafficDynamics < handle
    %TRAFFICDYNAMICS Mixed periodic + step + noise dynamics for traffic.

    properties
        enable logical = true
        periodRange = [300 500]
        amplitude = 0.4
        noiseStd = 0.05

        stream

        segmentEndSlot = 0
        period = 400
        phaseSin = 0
        phaseTri = 0

        stepValue = 0
        stepHoldSlots = 100
        nextStepSlot = 0
    end

    methods
        function obj = TrafficDynamics(dynamicCfg)
            if nargin < 1
                dynamicCfg = struct();
            end

            if isfield(dynamicCfg,'enable')
                obj.enable = logical(dynamicCfg.enable);
            end
            if isfield(dynamicCfg,'periodRange')
                obj.periodRange = dynamicCfg.periodRange;
            end
            if isfield(dynamicCfg,'intensity')
                obj.amplitude = obj.intensityToAmp(dynamicCfg.intensity);
            end
            if isfield(dynamicCfg,'noiseStd') && isnumeric(dynamicCfg.noiseStd)
                obj.noiseStd = max(0, dynamicCfg.noiseStd);
            end

            seed = 0;
            if isfield(dynamicCfg,'seed') && isnumeric(dynamicCfg.seed)
                seed = dynamicCfg.seed;
            end
            obj.stream = RandStream('mt19937ar','Seed',seed);

            obj = obj.resetSegment(0);
        end

        function out = get(obj, slotNow)
            if ~obj.enable
                out = obj.defaultOut();
                return;
            end

            if slotNow >= obj.segmentEndSlot
                obj = obj.resetSegment(slotNow);
            end

            mix1 = obj.mixWave(slotNow, 0.0);
            mix2 = obj.mixWave(slotNow, 0.33);
            mix3 = obj.mixWave(slotNow, 0.66);

            out = struct();
            out.overloadScale  = obj.clamp(1 + obj.amplitude * mix1, 0.4, 2.5);
            out.heavyMulScale  = obj.clamp(1 + obj.amplitude * mix2, 0.4, 2.5);
            out.silentMulScale = obj.clamp(1 + obj.amplitude * mix3, 0.2, 2.5);
            out.burstScale     = obj.clamp(1 + obj.amplitude * 0.8 * mix1, 0.3, 2.0);
        end
    end

    methods (Access=private)
        function obj = resetSegment(obj, slotNow)
            pr = obj.periodRange;
            if numel(pr) ~= 2 || pr(1) <= 0 || pr(2) < pr(1)
                pr = [300 500];
            end
            obj.period = round(pr(1) + (pr(2)-pr(1)) * rand(obj.stream));
            obj.period = max(obj.period, 50);

            obj.segmentEndSlot = slotNow + obj.period;

            obj.phaseSin = rand(obj.stream);
            obj.phaseTri = rand(obj.stream);

            obj.stepHoldSlots = max(20, round(0.25 * obj.period));
            obj.stepValue = 2 * rand(obj.stream) - 1;
            obj.nextStepSlot = slotNow + obj.stepHoldSlots;
        end

        function v = mixWave(obj, slotNow, phaseOffset)
            t = slotNow / max(obj.period,1);

            sinTerm = sin(2*pi*(t + obj.phaseSin + phaseOffset));

            triPhase = mod(t + obj.phaseTri + phaseOffset, 1);
            triTerm = 4 * abs(triPhase - 0.5) - 1;

            if slotNow >= obj.nextStepSlot
                obj.stepValue = 2 * rand(obj.stream) - 1;
                obj.nextStepSlot = slotNow + obj.stepHoldSlots;
            end
            stepTerm = obj.stepValue;

            noise = obj.noiseStd * randn(obj.stream);

            v = 0.55*sinTerm + 0.25*triTerm + 0.15*stepTerm + 0.05*noise;
            v = obj.clamp(v, -1, 1);
        end

        function out = defaultOut(~)
            out = struct();
            out.overloadScale = 1.0;
            out.heavyMulScale = 1.0;
            out.silentMulScale = 1.0;
            out.burstScale = 1.0;
        end

        function v = intensityToAmp(~, intensity)
            if isnumeric(intensity)
                v = max(0, min(1, intensity));
                return;
            end
            s = lower(string(intensity));
            if s == "low"
                v = 0.2;
            elseif s == "high"
                v = 0.6;
            elseif s == "medium"
                v = 0.4;
            else
                v = 0.4;
            end
        end

        function y = clamp(~, x, lo, hi)
            y = min(max(x, lo), hi);
        end
    end
end
