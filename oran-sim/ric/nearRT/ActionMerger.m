function final_action = ActionMerger(actions)
% ACTIONMERGER v2
%
% mergeMode options:
%   "overwrite" (default)
%   "average"
%   "random"

    mergeMode = "random";   % 🔥 在这里改策略 random average

    final_action = struct();

    final_action.scheduling = struct();
    final_action.power      = struct();
    final_action.sleep      = struct();
    final_action.handover   = struct();
    final_action.beam       = struct();

    final_action.control    = struct();

    final_action.metadata = struct();
    final_action.metadata.sources = {};

    if isempty(actions)
        return;
    end

    % 遍历所有 domain
    domains = ["scheduling","radio","energy","power","sleep","handover","beam"];

    for d = domains
        final_action.(d) = mergeDomainWithMode(actions, d, mergeMode);
    end

end

% ==============================================================
function mergedDomain = mergeDomainWithMode(actions, domain, mergeMode)

    mergedDomain = struct();

    fieldMap = containers.Map();

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

            tmp = fieldMap(key);
            tmp{end+1} = a.(domain).(key);
            fieldMap(key) = tmp;

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
