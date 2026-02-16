function final_action = ActionMerger(actions)
%ACTIONMERGER Merge multiple xApp actions into a single action (Stable)
%
% 支持两类 xApp 输出：
% 1) legacy: action.control.{key}
% 2) new:    action.{domain}.{field}   e.g. action.scheduling.selectedUE
%
% 合并规则：
% - domain 内字段覆盖：后来的 xApp 覆盖前面的
% - control 映射到 scheduling 的兼容逻辑在 NearRTRIC 做

    final_action = struct();

    % standard domains (aligned with RanActionBus)
    final_action.scheduling = struct();
    final_action.power      = struct();
    final_action.sleep      = struct();
    final_action.handover   = struct();
    final_action.beam       = struct();

    % legacy domain
    final_action.control    = struct();

    final_action.metadata = struct();
    final_action.metadata.sources = {};

    if isempty(actions)
        return;
    end

    for i = 1:numel(actions)

        a = actions{i};
        if isempty(a) || ~isstruct(a)
            continue;
        end

        % ---------- record source ----------
        src = "";
        if isfield(a,"metadata") && isstruct(a.metadata) && isfield(a.metadata,"xapp")
            src = string(a.metadata.xapp);
        else
            src = "xapp_" + string(i);
        end
        final_action.metadata.sources{end+1} = char(src); %#ok<AGROW>

        % ---------- merge legacy control ----------
        if isfield(a,"control") && isstruct(a.control)
            fn = fieldnames(a.control);
            for k = 1:numel(fn)
                key = fn{k};
                final_action.control.(key) = a.control.(key);
            end
        end

        % ---------- merge new domains ----------
        final_action = mergeDomain(final_action, a, "scheduling");
        final_action = mergeDomain(final_action, a, "power");
        final_action = mergeDomain(final_action, a, "sleep");
        final_action = mergeDomain(final_action, a, "handover");
        final_action = mergeDomain(final_action, a, "beam");
    end
end

function out = mergeDomain(out, a, domain)
    if isfield(a, domain) && isstruct(a.(domain))
        fn = fieldnames(a.(domain));
        for k = 1:numel(fn)
            key = fn{k};
            out.(domain).(key) = a.(domain).(key);
        end
    end
end
