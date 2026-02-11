classdef ActionGuard
%ACTIONGUARD Ensure action is valid and safe (MVP)

    properties
        cfg
    end

    methods
        function obj = ActionGuard(cfg)
            obj.cfg = cfg;
        end

        function action = guard(obj, rawAction, state)
        %GUARD Validate and clip action before sending to kernel
        
            cfg = obj.cfg;
        
            % rawAction 已经是完整 RanActionBus
            action = RanActionBus.validate(rawAction, cfg, state);
        
        end

    end
end
