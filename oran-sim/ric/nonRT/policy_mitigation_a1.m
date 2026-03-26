function [mergedXApps, mergedKpiFocus, conflicts] = policy_mitigation_a1(policies)
%POLICY_MITIGATION_A1 Detect policy conflicts and merge xApps

    if nargin < 1 || isempty(policies)
        mergedXApps = string.empty(1,0);
        mergedKpiFocus = string.empty(1,0);
        conflicts = struct('kpi', [], 'xapp', []);
        return;
    end

    % Normalize to struct array
    if ~isstruct(policies)
        mergedXApps = string.empty(1,0);
        mergedKpiFocus = string.empty(1,0);
        conflicts = struct('kpi', [], 'xapp', []);
        return;
    end

    numP = numel(policies);
    kpiConflicts = [];
    xappConflicts = [];

    % Merge xApps and KPI focus (active only)
    mergedXApps = string.empty(1,0);
    mergedKpiFocus = string.empty(1,0);
    kpiMap = containers.Map('KeyType','char','ValueType','any');
    xappMap = containers.Map('KeyType','char','ValueType','any');

    for i = 1:numP
        p = policies(i);
        if isfield(p,'status')
            st = string(p.status);
            if ~any(st == "active")
                continue;
            end
        end

        if isfield(p,'enabledXApps')
            xs = normalizeStringList(p.enabledXApps);
            mergedXApps = [mergedXApps; xs]; %#ok<AGROW>
            for xi = 1:numel(xs)
                key = char(xs(xi));
                if ~isKey(xappMap, key)
                    xappMap(key) = {getPolicyId(p, i)};
                else
                    xappMap(key) = [xappMap(key), {getPolicyId(p, i)}];
                end
            end
        end

        if isfield(p,'kpi_focus')
            ks = normalizeStringList(p.kpi_focus);
            mergedKpiFocus = [mergedKpiFocus; ks]; %#ok<AGROW>
            for ki = 1:numel(ks)
                key = char(ks(ki));
                if ~isKey(kpiMap, key)
                    kpiMap(key) = {getPolicyId(p, i)};
                else
                    kpiMap(key) = [kpiMap(key), {getPolicyId(p, i)}];
                end
            end
        end
    end

    mergedXApps = unique(mergedXApps, 'stable');
    mergedKpiFocus = unique(mergedKpiFocus, 'stable');

    % Conflict resolution (random winner for overlap items)
    kpiKeys = keys(kpiMap);
    for i = 1:numel(kpiKeys)
        key = kpiKeys{i};
        policiesForKey = kpiMap(key);
        if numel(policiesForKey) > 1
            winner = policiesForKey{randi(numel(policiesForKey))};
            c = struct();
            c.kpi = string(key);
            c.policies = string(policiesForKey);
            c.winner = string(winner);
            kpiConflicts = [kpiConflicts; c]; %#ok<AGROW>
        end
    end

    xappKeys = keys(xappMap);
    for i = 1:numel(xappKeys)
        key = xappKeys{i};
        policiesForKey = xappMap(key);
        if numel(policiesForKey) > 1
            winner = policiesForKey{randi(numel(policiesForKey))};
            c = struct();
            c.xapp = string(key);
            c.policies = string(policiesForKey);
            c.winner = string(winner);
            xappConflicts = [xappConflicts; c]; %#ok<AGROW>
        end
    end

    conflicts = struct();
    conflicts.kpi = kpiConflicts;
    conflicts.xapp = xappConflicts;
end

function pid = getPolicyId(p, fallback)
    if isfield(p,'policy_id')
        pid = p.policy_id;
    else
        pid = "policy_" + string(fallback);
    end
end

function out = normalizeStringList(value)

    if isstring(value)
        out = value(:);
        return;
    end

    if ischar(value)
        out = string(value);
        return;
    end

    if iscell(value)
        out = string(value(:));
        return;
    end

    out = string.empty(1,0);
end
