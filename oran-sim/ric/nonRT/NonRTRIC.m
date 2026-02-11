classdef NonRTRIC

    properties
        cfg
    end

    methods
        function obj = NonRTRIC(cfg)
            obj.cfg = cfg;
            fprintf('[Non-RT RIC] Initialized\n');
        end

        function step(obj, ranState)
            %#ok<INUSD>
            fprintf('[Non-RT RIC] Tick\n');
        end
    end
end
