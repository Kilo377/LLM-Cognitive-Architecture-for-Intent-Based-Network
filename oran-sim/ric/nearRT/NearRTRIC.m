classdef NearRTRIC
%NEARRTRIC Time-driven near-RT RIC (Repo-safe Stable Version)
%
% ==============================================================
% 角色定位
% --------------------------------------------------------------
% - near-RT RIC 负责：
%   1) 周期 tick 调度
%   2) 运行已启用的 xApp 集合
%   3) 合并 xApp 输出 (ActionMerger)
%   4) merged.control -> RanActionBus 映射
%   5) ActionGuard 安全裁剪
%
% - non-RT (rApp) 负责：
%   选择 enabledXApps 集合，通过 setPolicy() 下发
%
% - xApp 负责：
%   只输出 action.control.{key}
%
% ==============================================================
% 关键工程约束（GitHub 复现）
% --------------------------------------------------------------
% - 不依赖 pwd
% - xApp 根目录通过 cfg.nearRT.xappRoot 指定
% - 若目录不存在，直接报错，避免 silent baseline
% ==============================================================

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
    end

    methods
        function obj = NearRTRIC(cfg, varargin)
            % NearRTRIC(cfg, "xappSet", ["xapp_a","xapp_b"])
            %
            % cfg.nearRT.xappRoot 必须提供，建议使用绝对路径：
            %   cfg.nearRT.xappRoot = fullfile(rootDir,"xapps");

            obj.cfg = cfg;

            %% ---------------- Tick interval ----------------
            if isfield(cfg,'nearRT') && isfield(cfg.nearRT,'periodSlot')
                obj.tickIntervalSlot = cfg.nearRT.periodSlot;
            else
                obj.tickIntervalSlot = 10;
            end
            obj.nextTickSlot = 1;

            %% ---------------- Core adapters ----------------
            obj.obsAdapter  = ObsAdapter(cfg);
            obj.actionGuard = ActionGuard(cfg);

            %% ---------------- Cache ----------------
            obj.lastAction = RanActionBus.init(cfg);
            obj.lastActionSlot = 0;

            %% ---------------- Resolve xApp root ----------------
            obj.xappRoot = obj.resolveXAppRoot(cfg);

            %% ---------------- Load registry ----------------
            obj.xappRegistry = XAppRegistry(char(obj.xappRoot));
            obj.xappRegistry.load();

            xapps = obj.xappRegistry.getXApps();
            obj.xappManager = XAppManager(xapps);

            %% ---------------- Initial policy ----------------
            obj.policy = struct('enabledXApps', string.empty(1,0));
            obj.policyStamp = 0;
            obj.pendingPolicy = obj.policy;
            obj.pendingPolicyStamp = 0;

            fprintf('[near-RT RIC] init tickIntervalSlot=%d, xappRoot=%s, discovered=%d\n', ...
                obj.tickIntervalSlot, obj.xappRoot, numel(xapps));

            %% ---------------- Optional initial xAppSet ----------------
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
            % Triggered policy update (A1-like semantics)

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
            % E2-like semantics: run at tick slots

            slot = state.time.slot;

            info = struct();
            info.slot = slot;
            info.didTick = false;
            info.policyStamp = obj.policyStamp;

            %% non-tick -> cached action
            if slot < obj.nextTickSlot
                action = obj.lastAction;
                info.actionSource = "cache";
                return;
            end

            %% tick -> apply policy first
            obj = obj.applyPendingPolicyIfAny();

            %% build obs
            obs = obj.obsAdapter.buildObs(state);

            %% build input
            ctx = struct();
            ctx.time = state.time;
            ctx.trigger = "periodic";
            input = InputBuilder(obs, obj.cfg, ctx);

            %% run enabled xApps
            actions = obj.xappManager.run(input, "periodic");

            %% merge
            merged = ActionMerger(actions);

            %% map merged.control -> RanActionBus
            rawAction = RanActionBus.init(obj.cfg);

            domains = fieldnames(rawAction);
            
            for di = 1:numel(domains)
                d = domains{di};
            
                if isfield(merged, d) && isstruct(merged.(d))
                    fn = fieldnames(merged.(d));
                    for fi = 1:numel(fn)
                        key = fn{fi};
                        rawAction.(d).(key) = merged.(d).(key);
                    end
                end
            end


            %% guard
            action = obj.actionGuard.guard(rawAction, state);

            %% update cache
            obj.lastAction = action;
            obj.lastActionSlot = slot;

            %% schedule next tick
            obj.nextTickSlot = slot + obj.tickIntervalSlot;

            %% info
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

        function xroot = resolveXAppRoot(obj, cfg)
            % Resolve xApp root robustly (repo-safe)
            %
            % Priority:
            % 1) cfg.nearRT.xappRoot
            % 2) error (avoid silent baseline)

            if ~(isfield(cfg,'nearRT') && isfield(cfg.nearRT,'xappRoot'))
                error('NearRTRIC:MissingXAppRoot', ...
                    'cfg.nearRT.xappRoot is required. Set it in run script (recommended absolute path).');
            end

            xroot = string(cfg.nearRT.xappRoot);

            % If relative path, resolve relative to this class file directory
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
            % Apply pending policy only at tick boundary

            if obj.pendingPolicyStamp <= obj.policyStamp
                return;
            end

            obj.policy = obj.pendingPolicy;
            obj.policyStamp = obj.pendingPolicyStamp;

            obj = obj.applyXAppEnableList(obj.policy);

            fprintf('[near-RT RIC] policy applied stamp=%d\n', obj.policyStamp);
        end

        function newPolicy = normalizePolicy(obj, newPolicy)
            % Normalize new policy format
            %
            % Supported:
            % - newPolicy.enabledXApps
            % Legacy:
            % - newPolicy.selectedXApp

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

            newPolicy = obj.policy;
        end

        function obj = applyXAppEnableList(obj, policy)
            % Turn all xApps off, then turn on those in policy.enabledXApps

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
        
            % 1) new domains first: merged.scheduling -> rawAction.scheduling
            if isfield(merged,'scheduling') && isstruct(merged.scheduling)
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
            % Default mapping + allow cfg override

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
            % Set nested struct field by string path "a.b.c"

            parts = split(string(path), ".");
            parts = cellstr(parts);

            if numel(parts) == 1
                s.(parts{1}) = value;
                return;
            end

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
