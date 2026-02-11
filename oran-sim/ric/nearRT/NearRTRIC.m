classdef NearRTRIC
%NEARRTRIC Time-driven near-RT RIC skeleton (New MVP)
%
% changes:
% - use XAppRegistry + XAppManager to load/run xApps
% - use InputBuilder to build unified input
% - use ActionMerger to merge multiple xApp actions
% - convert merged action.control into RanActionBus before ActionGuard
% - keep tick/cache semantics

    properties
        cfg

        % tick control
        tickIntervalSlot
        nextTickSlot

        % policy (A1 semantics)
        policy = struct()
        policyStamp = 0
        pendingPolicy = struct()
        pendingPolicyStamp = 0

        % adapters
        obsAdapter
        actionGuard

        % new modules
        xappRoot
        xappRegistry
        xappManager

        % action cache
        lastAction
        lastActionSlot = 0
    end

    methods
        function obj = NearRTRIC(cfg)
            obj.cfg = cfg;

            % tick interval
            if isfield(cfg,'nearRT') && isfield(cfg.nearRT,'periodSlot')
                obj.tickIntervalSlot = cfg.nearRT.periodSlot;
            else
                obj.tickIntervalSlot = 10;
            end
            obj.nextTickSlot = 1;

            obj.obsAdapter  = ObsAdapter(cfg);
            obj.actionGuard = ActionGuard(cfg);

            obj.lastAction = RanActionBus.init(cfg);

            % xapp root
            if isfield(cfg,'nearRT') && isfield(cfg.nearRT,'xappRoot')
                obj.xappRoot = string(cfg.nearRT.xappRoot);
            else
                obj.xappRoot = "xapps";
            end

            % load registry
            obj.xappRegistry = XAppRegistry(char(obj.xappRoot));
            obj.xappRegistry.load();
            xapps = obj.xappRegistry.getXApps();

            % create manager
            obj.xappManager = XAppManager(xapps);

            % initial policy
            % new policy format:
            %   policy.enabledXApps = ["mac_scheduler_urllc", ...]
            % keep legacy:
            %   policy.selectedXApp = "xxx"
            obj.policy = struct('enabledXApps', string.empty(1,0));
            obj.policyStamp = 0;
            obj.pendingPolicy = obj.policy;
            obj.pendingPolicyStamp = obj.policyStamp;

            fprintf('[near-RT RIC] init tickIntervalSlot=%d, xappRoot=%s, discovered=%d\n', ...
                obj.tickIntervalSlot, obj.xappRoot, numel(xapps));
        end

        function obj = setPolicy(obj, newPolicy)
            %SETPOLICY Triggered policy update from non-RT

            if ~isstruct(newPolicy)
                return;
            end

            % normalize policy
            newPolicy = obj.normalizePolicy(newPolicy);

            obj.pendingPolicy = newPolicy;
            obj.pendingPolicyStamp = obj.policyStamp + 1;

            if isfield(newPolicy,'enabledXApps')
                fprintf('[near-RT RIC] policy update received: enabledXApps=%s (pending)\n', ...
                    mat2str(string(newPolicy.enabledXApps)));
            end
        end

        function [obj, action, info] = step(obj, state)
            slot = state.time.slot;

            info = struct();
            info.slot = slot;
            info.didTick = false;
            info.policyStamp = obj.policyStamp;

            % non-tick
            if slot < obj.nextTickSlot
                action = obj.lastAction;
                info.actionSource = "cache";
                return;
            end

            % tick
            obj = obj.applyPendingPolicyIfAny();

            % build obs
            obs = obj.obsAdapter.buildObs(state);

            % build input
            ctx = struct();
            ctx.time = state.time;
            ctx.trigger = "periodic";
            input = InputBuilder(obs, obj.cfg, ctx);

            % run xApps
            actions = obj.xappManager.run(input, "periodic");

            % merge
            merged = ActionMerger(actions);

            % convert to RanActionBus
            rawAction = RanActionBus.init(obj.cfg);
            rawAction = obj.applyControl(rawAction, merged);

            % guard
            action = obj.actionGuard.guard(rawAction, state);

            % update cache
            obj.lastAction = action;
            obj.lastActionSlot = slot;

            % update tick schedule
            obj.nextTickSlot = slot + obj.tickIntervalSlot;

            info.didTick = true;
            info.actionSource = "xApps";
            info.policyStamp = obj.policyStamp;

            if isfield(merged,'metadata') && isfield(merged.metadata,'sources')
                info.xAppSources = merged.metadata.sources;
            else
                info.xAppSources = {};
            end
        end
    end

    methods (Access = private)

        function obj = applyPendingPolicyIfAny(obj)
            if obj.pendingPolicyStamp <= obj.policyStamp
                return;
            end

            obj.policy = obj.pendingPolicy;
            obj.policyStamp = obj.pendingPolicyStamp;

            % apply enable/disable
            obj = obj.applyXAppEnableList(obj.policy);

            fprintf('[near-RT RIC] policy applied stamp=%d\n', obj.policyStamp);
        end

        function newPolicy = normalizePolicy(obj, newPolicy)
            % support legacy selectedXApp
            if isfield(newPolicy,'enabledXApps')
                newPolicy.enabledXApps = string(newPolicy.enabledXApps);
                return;
            end

            if isfield(newPolicy,'selectedXApp')
                sx = string(newPolicy.selectedXApp);
                if sx == "none" || strlength(sx) == 0
                    newPolicy = struct('enabledXApps', string.empty(1,0));
                else
                    newPolicy = struct('enabledXApps', sx);
                end
                return;
            end

            % fallback
            newPolicy = obj.policy;
        end

        function obj = applyXAppEnableList(obj, policy)
            % set all off
            for i = 1:numel(obj.xappManager.xapps)
                obj.xappManager.xapps(i).status = "off";
            end

            if ~isfield(policy,'enabledXApps')
                return;
            end

            list = string(policy.enabledXApps);

            for k = 1:numel(list)
                obj.xappManager.setXAppStatus(list(k), "on");
            end
        end

        function rawAction = applyControl(obj, rawAction, merged)
            % merged.control -> RanActionBus fields (MVP mapping)

            if ~isstruct(merged) || ~isfield(merged,'control') || ~isstruct(merged.control)
                return;
            end

            control = merged.control;

            % mapping table
            map = obj.getControlMap();

            keys = fieldnames(control);
            for i = 1:numel(keys)
                key = keys{i};

                if isfield(map, key)
                    path = map.(key);
                    rawAction = obj.setByPath(rawAction, path, control.(key));
                else
                    % fallback: try direct top-level assign if exists
                    if isfield(rawAction, key)
                        rawAction.(key) = control.(key);
                    end
                end
            end
        end

        function map = getControlMap(obj)
            % default map
            map = struct();
            map.selectedUE = "scheduling.selectedUE";

            % allow cfg override
            if isfield(obj.cfg,'nearRT') && isfield(obj.cfg.nearRT,'controlMap')
                try
                    userMap = obj.cfg.nearRT.controlMap;
                    f = fieldnames(userMap);
                    for i = 1:numel(f)
                        map.(f{i}) = string(userMap.(f{i}));
                    end
                catch
                end
            end
        end

        function s = setByPath(~, s, path, value)
            % path like "a.b.c"
            parts = split(string(path), ".");
            parts = cellstr(parts);

            if numel(parts) == 1
                s.(parts{1}) = value;
                return;
            end

            % recursive set
            s.(parts{1}) = NearRTRIC.setByPathInner(s.(parts{1}), parts(2:end), value);
        end
    end

    methods (Static, Access = private)
        function sub = setByPathInner(sub, parts, value)
            if numel(parts) == 1
                sub.(parts{1}) = value;
                return;
            end
            sub.(parts{1}) = NearRTRIC.setByPathInner(sub.(parts{1}), parts(2:end), value);
        end
    end
end
