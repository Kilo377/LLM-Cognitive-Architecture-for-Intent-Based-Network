function final_action = ActionMerger(actions)
% ACTIONMERGER v2
%
% mergeMode options:
%   "overwrite" (default)
%   "average"
%   "random"

    mergeMode = "random";   % 🔥 在这里改策略 random average
    tol = 1e-4;

    final_action = struct();

    final_action.scheduling = struct();
    final_action.sleep      = struct();
    final_action.handover   = struct();
    final_action.beam       = struct();

    final_action.control    = struct();

    final_action.metadata = struct();
    final_action.metadata.sources = {};
    final_action.metadata.lastConflict = struct();

    if isempty(actions)
        return;
    end

    % 遍历所有 domain
    domains = ["scheduling","radio","energy","sleep","handover","beam"];

    for d = domains
        [final_action.(d), conflict] = mergeDomainWithMode(actions, d, mergeMode, tol);
        if d == "handover" && ~isempty(fieldnames(conflict))
            final_action.metadata.lastConflict = conflict;
        end
    end

    final_action.metadata.sources = collectSources(actions);

end

% ==============================================================
function [mergedDomain, lastConflict] = mergeDomainWithMode(actions, domain, mergeMode, tol)

    mergedDomain = struct();
    lastConflict = struct();

    fieldMap = containers.Map();
    srcMap = containers.Map();

    % 收集所有字段
    for i = 1:numel(actions)

        a = actions{i};
        if ~isfield(a, domain)
            continue;
        end

        fn = fieldnames(a.(domain));

        for k = 1:numel(fn)

            key = fn{k};

            if ~isKey(fieldMap, key)
                fieldMap(key) = {};
            end
            if ~isKey(srcMap, key)
                srcMap(key) = {};
            end

            tmp = fieldMap(key);
            tmp{end+1} = a.(domain).(key);
            fieldMap(key) = tmp;

            srcTmp = srcMap(key);
            srcTmp{end+1} = getSourceId(a);
            srcMap(key) = srcTmp;

        end
    end

    % 逐字段合并
    keys = fieldMap.keys;

    for i = 1:numel(keys)

        key = keys{i};
        values = fieldMap(key);

        if numel(values) == 1
            mergedDomain.(key) = values{1};
            continue;
        end

        if domain == "handover"
            sources = srcMap(key);
            if hasConflict(values, tol)
                lastConflict = struct();
                lastConflict.domain = "handover";
                lastConflict.field = key;
                lastConflict.sources = sources;
                lastConflict.values = values;
                lastConflict.mergeMode = mergeMode;
            end
        end

        switch mergeMode

            case "overwrite"
                mergedDomain.(key) = values{end};

            case "average"
                if isnumeric(values{1})
                    acc = 0;
                    for j = 1:numel(values)
                        acc = acc + values{j};
                    end
                    mergedDomain.(key) = acc / numel(values);
                else
                    mergedDomain.(key) = values{end};
                end

            case "random"
                idx = randi(numel(values));
                mergedDomain.(key) = values{idx};

        end
    end
end

function sources = collectSources(actions)
    sources = strings(0,1);
    for i = 1:numel(actions)
        a = actions{i};
        src = getSourceId(a);
        if strlength(src) > 0
            sources(end+1,1) = src; %#ok<AGROW>
        end
    end
end

function src = getSourceId(action)
    src = "";
    if isfield(action,'metadata') && isfield(action.metadata,'source')
        src = string(action.metadata.source);
    end
end

function tf = hasConflict(values, tol)
    if numel(values) <= 1
        tf = false;
        return;
    end
    if isnumeric(values{1})
        try
            vmin = values{1};
            vmax = values{1};
            for i = 2:numel(values)
                vmin = min(vmin, values{i});
                vmax = max(vmax, values{i});
            end
            tf = any(abs(vmax - vmin) > tol, 'all');
        catch
            tf = true;
        end
    else
        tf = false;
        for i = 2:numel(values)
            if ~isequal(values{1}, values{i})
                tf = true;
                return;
            end
        end
    end
end
