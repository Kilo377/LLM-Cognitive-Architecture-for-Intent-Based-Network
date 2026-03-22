classdef MobilityTrend < handle
    %MOBILITYTREND Trend-driven edge migration profile.

    properties
        enable logical = true
        startSlot = 300
        endSlot = 900
        edgeBiasRange = [0.0 1.0]
    end

    methods
        function obj = MobilityTrend(trendCfg)
            if nargin < 1
                trendCfg = struct();
            end

            if isfield(trendCfg,'enable'), obj.enable = logical(trendCfg.enable); end
            if isfield(trendCfg,'startSlot'), obj.startSlot = trendCfg.startSlot; end
            if isfield(trendCfg,'endSlot'), obj.endSlot = trendCfg.endSlot; end
            if isfield(trendCfg,'edgeBiasRange'), obj.edgeBiasRange = trendCfg.edgeBiasRange; end
        end

        function out = get(obj, slotNow)
            out = struct();
            if ~obj.enable
                out.factor = 0;
                out.edgeBias = 0;
                return;
            end

            f = obj.trendFactor(slotNow);
            out.factor = f;
            out.edgeBias = obj.lerp(obj.edgeBiasRange, f);
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
                v = 0.0;
                return;
            end
            v = range(1) + (range(2) - range(1)) * f;
        end
    end
end
