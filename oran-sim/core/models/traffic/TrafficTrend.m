classdef TrafficTrend < handle
    %TRAFFICTREND Trend-driven load growth profile.

    properties
        enable logical = true
        startSlot = 300
        endSlot = 900

        loadRange = [1.2 2.6]
        heavyMulRange = [1.0 2.1]
        activeUERange = [0.5 1.0]

        burstOnScaleRange = [1.0 1.6]
        burstOffScaleRange = [1.0 0.6]
    end

    methods
        function obj = TrafficTrend(trendCfg)
            if nargin < 1
                trendCfg = struct();
            end

            if isfield(trendCfg,'enable'), obj.enable = logical(trendCfg.enable); end
            if isfield(trendCfg,'startSlot'), obj.startSlot = trendCfg.startSlot; end
            if isfield(trendCfg,'endSlot'), obj.endSlot = trendCfg.endSlot; end
            if isfield(trendCfg,'loadRange'), obj.loadRange = trendCfg.loadRange; end
            if isfield(trendCfg,'heavyMulRange'), obj.heavyMulRange = trendCfg.heavyMulRange; end
            if isfield(trendCfg,'activeUERange'), obj.activeUERange = trendCfg.activeUERange; end
            if isfield(trendCfg,'burstOnScaleRange'), obj.burstOnScaleRange = trendCfg.burstOnScaleRange; end
            if isfield(trendCfg,'burstOffScaleRange'), obj.burstOffScaleRange = trendCfg.burstOffScaleRange; end
        end

        function out = get(obj, slotNow)
            out = struct();
            if ~obj.enable
                out.factor = 0;
                out.overloadScale = 1.0;
                out.heavyMulScale = 1.0;
                out.activeRatio = 1.0;
                out.burstOnScale = 1.0;
                out.burstOffScale = 1.0;
                return;
            end

            f = obj.trendFactor(slotNow);

            out.factor = f;
            out.overloadScale = obj.lerp(obj.loadRange, f);
            out.heavyMulScale = obj.lerp(obj.heavyMulRange, f);
            out.activeRatio = obj.lerp(obj.activeUERange, f);
            out.burstOnScale = obj.lerp(obj.burstOnScaleRange, f);
            out.burstOffScale = obj.lerp(obj.burstOffScaleRange, f);
        end
    end

    methods (Access=private)
        function f = trendFactor(obj, slotNow)
            if slotNow <= obj.startSlot
                f = 0;
                return;
            end
            if slotNow >= obj.endSlot
                f = 1;
                return;
            end
            f = (double(slotNow) - double(obj.startSlot)) / max(double(obj.endSlot - obj.startSlot), 1);
            f = min(max(f,0),1);
        end

        function v = lerp(~, range, f)
            if numel(range) ~= 2
                v = 1.0;
                return;
            end
            v = range(1) + (range(2) - range(1)) * f;
        end
    end
end
