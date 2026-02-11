function final_action = ActionMerger(actions)
%ACTIONMERGER Merge multiple xApp actions into a single action (MVP)
%
% rules:
%  - merge action.control only
%  - later xApp overwrites earlier xApp on conflict
%  - collect metadata for debugging

    final_action = struct();
    final_action.control = struct();
    final_action.metadata = struct();
    final_action.metadata.sources = {};

    if isempty(actions)
        return;
    end

    for i = 1:numel(actions)

        a = actions{i};
        if isempty(a)
            continue;
        end
        if ~isstruct(a)
            continue;
        end

        % record source
        src = "";
        if isfield(a, "metadata") && isstruct(a.metadata) && isfield(a.metadata, "xapp")
            src = string(a.metadata.xapp);
        else
            src = "xapp_" + string(i);
        end
        final_action.metadata.sources{end+1} = char(src); %#ok<AGROW>

        % merge control
        if isfield(a, "control") && isstruct(a.control)
            fn = fieldnames(a.control);
            for k = 1:numel(fn)
                key = fn{k};
                final_action.control.(key) = a.control.(key);
            end
        end
    end
end
