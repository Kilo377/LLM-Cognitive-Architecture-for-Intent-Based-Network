classdef NearRTRIC
%NEARRTRIC Time-driven near-RT RIC (Repo-safe Stable Version)
%
% Role
% - near-RT RIC runs xApps.
% - near-RT RIC merges xApp outputs.
% - near-RT RIC maps merged domains into RanActionBus.
% - near-RT RIC guards actions.
% - non-RT rApp sets enabled xApps by setPolicy().
%
% Contract
% - xApp can output new domains (action.scheduling, action.radio, ...).
% - xApp can output legacy control (action.control.{key}).
% - NearRTRIC maps legacy control by controlMap.

    properties
        cfg

        % tick control
        tickIntervalSlot
        nextTickSlot

        % policy
        policy
        policyStamp
        pendingPolicy
        pendingPolicyStamp

        % adapters
        obsAdapter
        actionGuard

        % xApp modules
        xappRoot
        xappRegistry
        xappManager

        % action cache
        lastAction
        lastActionSlot

        lastConflict

        % debug
        debugEnable
    end

    methods
        function obj = NearRTRIC(cfg, varargin)

            obj.cfg = cfg;

            % debug flag
            obj.debugEnable = false;
            if isfield(cfg,'debug') && isfield(cfg.debug,'enableNearRT')
                obj.debugEnable = logical(cfg.debug.enableNearRT);
            end

            % tick interval
            if isfield(cfg,'nearRT') && isfield(cfg.nearRT,'periodSlot')
                obj.tickIntervalSlot = cfg.nearRT.periodSlot;
            else
                obj.tickIntervalSlot = 10;
            end
            obj.nextTickSlot = 1;

            % adapters
            obj.obsAdapter  = ObsAdapter(cfg);
            obj.actionGuard = ActionGuard(cfg);

            % cache
            obj.lastAction = RanActionBus.init(cfg);
            obj.lastActionSlot = 0;
            obj.lastConflict = struct();

            % resolve xApp root
            obj.xappRoot = obj.resolveXAppRoot(cfg);

            % registry + manager
            obj.xappRegistry = XAppRegistry(char(obj.xappRoot));
            obj.xappRegistry.load();
            xapps = obj.xappRegistry.getXApps();
            obj.xappManager = XAppManager(xapps);

            % initial policy
            obj.policy = struct('enabledXApps', string.empty(1,0));
            obj.policyStamp = 0;
            obj.pendingPolicy = obj.policy;
            obj.pendingPolicyStamp = 0;

            fprintf('[near-RT RIC] init tickIntervalSlot=%d, xappRoot=%s, discovered=%d\n', ...
                obj.tickIntervalSlot, obj.xappRoot, numel(xapps));

            % optional initial xAppSet
            if ~isempty(varargin)
                for i = 1:2:length(varargin)
                    key = varargin{i};
                    value = varargin{i+1};
                    if strcmpi(key, "xappSet")
                        p = struct();
                        p.enabledXApps = string(value);
                        obj = obj.setPolicy(p);
                        fprintf('[near-RT RIC] initial xAppSet applied\n');
                    end
                end
            end
        end

        function obj = setPolicy(obj, newPolicy)


            if ~isstruct(newPolicy)
                return;
            end

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

            % tick: apply policy
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

            if isfield(merged,'metadata') && isfield(merged.metadata,'lastConflict') && ...
                    ~isempty(fieldnames(merged.metadata.lastConflict))
                obj.lastConflict = merged.metadata.lastConflict;
                obj.lastConflict.slot = slot;
            end

            % init raw bus
            rawAction = RanActionBus.init(obj.cfg);

            % map merged -> rawAction (NEW + legacy)
            rawAction = obj.applyControl(rawAction, merged);

            % guard
            action = obj.actionGuard.guard(rawAction, state);

            % cache
            obj.lastAction = action;
            obj.lastActionSlot = slot;

            % next tick
            obj.nextTickSlot = slot + obj.tickIntervalSlot;

            % info
            info.didTick = true;
            info.actionSource = "xApps";
            info.policyStamp = obj.policyStamp;

            if isfield(merged,'metadata') && isfield(merged.metadata,'sources')
                info.xAppSources = merged.metadata.sources;
            else
                info.xAppSources = {};
            end

            % debug print
            if obj.debugEnable
                obj.printDebug(slot, merged, rawAction, action, info);
            end
        end
    end

    methods (Access = private)

        function xroot = resolveXAppRoot(~, cfg)

            if ~(isfield(cfg,'nearRT') && isfield(cfg.nearRT,'xappRoot'))
                error('NearRTRIC:MissingXAppRoot', ...
                    'cfg.nearRT.xappRoot is required. Set it in run script.');
            end

            xroot = string(cfg.nearRT.xappRoot);

            if ~isfolder(xroot)
                baseDir = fileparts(mfilename('fullpath'));
                cand = fullfile(baseDir, xroot);
                if isfolder(cand)
                    xroot = string(cand);
                end
            end

            if ~isfolder(xroot)
                error('NearRTRIC:XAppRootNotFound', ...
                    'xApp root folder not found: %s', xroot);
            end
        end

        function obj = applyPendingPolicyIfAny(obj)


            if obj.pendingPolicyStamp <= obj.policyStamp
                return;
            end

            obj.policy = obj.pendingPolicy;
            obj.policyStamp = obj.pendingPolicyStamp;

            obj = obj.applyXAppEnableList(obj.policy);

            fprintf('[near-RT RIC] policy applied stamp=%d\n', obj.policyStamp);
        end

        function newPolicy = normalizePolicy(~, newPolicy)


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

            newPolicy = struct('enabledXApps', string.empty(1,0));
        end

        function obj = applyXAppEnableList(obj, policy)


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


            map = obj.getControlMap();

            % 0) direct copy for domains that exist in rawAction
            rawDomains = fieldnames(rawAction);
            for di = 1:numel(rawDomains)
                d = rawDomains{di};
                if isfield(merged, d) && isstruct(merged.(d))
                    fn = fieldnames(merged.(d));
                    for fi = 1:numel(fn)
                        key = fn{fi};
                        rawAction.(d).(key) = merged.(d).(key);
                    end
                end
            end

            % 1) ensure scheduling domain exists if merged has it
            if isfield(merged,'scheduling') && isstruct(merged.scheduling)
                if ~isfield(rawAction,'scheduling') || ~isstruct(rawAction.scheduling)
                    rawAction.scheduling = struct();
                end
                fn = fieldnames(merged.scheduling);
                for i = 1:numel(fn)
                    key = fn{i};
                    rawAction.scheduling.(key) = merged.scheduling.(key);
                end
            end

            % 2) legacy control mapping: merged.control -> rawAction by map
            if isfield(merged,'control') && isstruct(merged.control)
                control = merged.control;
                keys = fieldnames(control);
                for i = 1:numel(keys)
                    key = keys{i};
                    if isfield(map, key)
                        path = map.(key);
                        rawAction = obj.setByPath(rawAction, path, control.(key));
                    elseif isfield(rawAction, key)
                        rawAction.(key) = control.(key);
                    end
                end
            end
        end

        function map = getControlMap(obj)


            map = struct();
            map.selectedUE = "scheduling.selectedUE";

            if isfield(obj.cfg,'nearRT') && isfield(obj.cfg.nearRT,'controlMap')
                userMap = obj.cfg.nearRT.controlMap;
                f = fieldnames(userMap);
                for i = 1:numel(f)
                    map.(f{i}) = string(userMap.(f{i}));
                end
            end
        end

        function s = setByPath(~, s, path, value)


            parts = split(string(path), ".");
            parts = cellstr(parts);

            if numel(parts) == 1
                s.(parts{1}) = value;
                return;
            end

            if ~isfield(s, parts{1}) || ~isstruct(s.(parts{1}))
                s.(parts{1}) = struct();
            end

            s.(parts{1}) = NearRTRIC.setByPathInner(s.(parts{1}), parts(2:end), value);
        end

        function printDebug(~, slot, merged, rawAction, guardedAction, info)


            fprintf('[near-RT RIC][DEBUG] slot=%d didTick=%d policyStamp=%d\n', ...
                slot, info.didTick, info.policyStamp);

            if isfield(merged,'scheduling') && isfield(merged.scheduling,'selectedUE')
                fprintf('  merged.scheduling.selectedUE=%s\n', mat2str(merged.scheduling.selectedUE(:).'));
            end
            if isfield(rawAction,'scheduling') && isfield(rawAction.scheduling,'selectedUE')
                fprintf('  rawAction.scheduling.selectedUE=%s\n', mat2str(rawAction.scheduling.selectedUE(:).'));
            end
            if isfield(guardedAction,'scheduling') && isfield(guardedAction.scheduling,'selectedUE')
                fprintf('  guarded.scheduling.selectedUE=%s\n', mat2str(guardedAction.scheduling.selectedUE(:).'));
            end
        end
    end

    methods (Static, Access = private)
        function sub = setByPathInner(sub, parts, value)
            if numel(parts) == 1
                sub.(parts{1}) = value;
                return;
            end

            if ~isfield(sub, parts{1}) || ~isstruct(sub.(parts{1}))
                sub.(parts{1}) = struct();
            end

            sub.(parts{1}) = NearRTRIC.setByPathInner(sub.(parts{1}), parts(2:end), value);
        end
    end
end
