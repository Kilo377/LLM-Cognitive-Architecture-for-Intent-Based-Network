classdef NearRTRIC
%NEARRTRIC Time-driven near-RT RIC (Stable Version)
%
% ==============================================================
% 角色定位
% --------------------------------------------------------------
% - near-RT RIC 负责：
%     1) 周期性 tick 调度
%     2) 运行已启用的 xApp 集合
%     3) 合并 xApp 输出
%     4) 映射为 RanActionBus
%     5) 进行安全裁剪
%
% - non-RT (rApp) 负责：
%     选择 enabledXApps 集合
%     通过 setPolicy() 下发
%
% - xApp：
%     只输出 action.control
%
% ==============================================================

    properties

        %% ===========================
        % Configuration
        %% ===========================
        cfg

        %% ===========================
        % Tick control
        %% ===========================
        tickIntervalSlot      % near-RT 周期
        nextTickSlot          % 下次触发 slot

        %% ===========================
        % Policy (A1 semantics)
        %% ===========================
        policy                % 当前生效策略
        policyStamp           % 当前策略版本
        pendingPolicy         % 待切换策略
        pendingPolicyStamp    % 待切换版本号

        %% ===========================
        % Adapters
        %% ===========================
        obsAdapter
        actionGuard

        %% ===========================
        % xApp related modules
        %% ===========================
        xappRoot
        xappRegistry
        xappManager

        %% ===========================
        % Action cache
        %% ===========================
        lastAction
        lastActionSlot
    end

    %% ==========================================================
    % Constructor
    %% ==========================================================
    methods

        function obj = NearRTRIC(cfg, varargin)
        % Constructor
        %
        % Optional:
        %   NearRTRIC(cfg, "xappSet", ["xapp_a","xapp_b"])

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

            obj.lastAction = RanActionBus.init(cfg);
            obj.lastActionSlot = 0;

            %% ---------------- xApp root ----------------
            if isfield(cfg,'nearRT') && isfield(cfg.nearRT,'xappRoot')
                obj.xappRoot = string(cfg.nearRT.xappRoot);
            else
                obj.xappRoot = "xapps";
            end

            %% ---------------- Load xApps ----------------
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

        %% ==========================================================
        % Policy update from non-RT
        %% ==========================================================
        function obj = setPolicy(obj, newPolicy)

            if ~isstruct(newPolicy)
                return;
            end

            newPolicy = obj.normalizePolicy(newPolicy);

            obj.pendingPolicy = newPolicy;
            obj.pendingPolicyStamp = obj.policyStamp + 1;

            if isfield(newPolicy,'enabledXApps')
                fprintf('[near-RT RIC] policy update received (pending)\n');
            end
        end

        %% ==========================================================
        % Main step (E2 semantics)
        %% ==========================================================
        function [obj, action, info] = step(obj, state)

            slot = state.time.slot;

            info = struct();
            info.slot = slot;
            info.didTick = false;
            info.policyStamp = obj.policyStamp;

            %% -------- Non-tick: reuse cache --------
            if slot < obj.nextTickSlot
                action = obj.lastAction;
                info.actionSource = "cache";
                return;
            end

            %% -------- Tick start --------
            obj = obj.applyPendingPolicyIfAny();

            %% -------- Build observation --------
            obs = obj.obsAdapter.buildObs(state);

            %% -------- Build unified input --------
            ctx = struct();
            ctx.time = state.time;
            ctx.trigger = "periodic";

            input = InputBuilder(obs, obj.cfg, ctx);

            %% -------- Run xApps --------
            actions = obj.xappManager.run(input, "periodic");

            %% -------- Merge actions --------
            merged = ActionMerger(actions);

            %% -------- Map to RanActionBus --------
            rawAction = RanActionBus.init(obj.cfg);
            rawAction = obj.applyControl(rawAction, merged);

            %% -------- Safety guard --------
            action = obj.actionGuard.guard(rawAction, state);

            %% -------- Cache update --------
            obj.lastAction = action;
            obj.lastActionSlot = slot;

            %% -------- Update next tick --------
            obj.nextTickSlot = slot + obj.tickIntervalSlot;

            %% -------- Info --------
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

    %% ==========================================================
    % Internal helpers
    %% ==========================================================
    methods (Access = private)

        function obj = applyPendingPolicyIfAny(obj)

            if obj.pendingPolicyStamp <= obj.policyStamp
                return;
            end

            obj.policy = obj.pendingPolicy;
            obj.policyStamp = obj.pendingPolicyStamp;

            obj = obj.applyXAppEnableList(obj.policy);

            fprintf('[near-RT RIC] policy applied stamp=%d\n', obj.policyStamp);
        end

        function newPolicy = normalizePolicy(obj, newPolicy)

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

            if ~isstruct(merged) || ~isfield(merged,'control')
                return;
            end

            control = merged.control;
            map = obj.getControlMap();

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

