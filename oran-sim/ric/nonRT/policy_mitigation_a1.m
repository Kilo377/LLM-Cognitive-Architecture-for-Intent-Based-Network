function [mergedXApps, conflicts] = policy_mitigation_a1(policies)
%POLICY_MITIGATION_A1 Detect policy conflicts and merge xApps

    if nargin < 1 || isempty(policies)
        mergedXApps = string.empty(1,0);
        conflicts = struct('kpi', [], 'xapp', []);
        return;
    end

    % Normalize to struct array
    if ~isstruct(policies)
        mergedXApps = string.empty(1,0);
        conflicts = struct('kpi', [], 'xapp', []);
        return;
    end

    numP = numel(policies);
    kpiConflicts = [];
    xappConflicts = [];

    % Merge xApps (active only)
    mergedXApps = string.empty(1,0);

    for i = 1:numP
        p = policies(i);
        if isfield(p,'status')
            st = string(p.status);
            if ~any(st == "active")
                continue;
            end
        end

        if isfield(p,'enabledXApps')
            mergedXApps = [mergedXApps; string(p.enabledXApps(:))]; %#ok<AGROW>
        end
    end

    mergedXApps = unique(mergedXApps, 'stable');

    % Conflict detection (pairwise)
    for i = 1:numP
        for j = i+1:numP
            pa = policies(i);
            pb = policies(j);

            if isfield(pa,'status')
                stA = string(pa.status);
                if ~any(stA == "active")
                    continue;
                end
            end
            if isfield(pb,'status')
                stB = string(pb.status);
                if ~any(stB == "active")
                    continue;
                end
            end

            % KPI conflict
            kpiA = string.empty(1,0);
            kpiB = string.empty(1,0);
            if isfield(pa,'kpi_focus')
                kpiA = string(pa.kpi_focus(:));
            end
            if isfield(pb,'kpi_focus')
                kpiB = string(pb.kpi_focus(:));
            end
            kpiOverlap = intersect(kpiA, kpiB);
            if ~isempty(kpiOverlap)
                c = struct();
                c.policy_a = string(getPolicyId(pa, i));
                c.policy_b = string(getPolicyId(pb, j));
                c.kpi = kpiOverlap;
                kpiConflicts = [kpiConflicts; c]; %#ok<AGROW>
            end

            % xApp conflict
            xA = string.empty(1,0);
            xB = string.empty(1,0);
            if isfield(pa,'enabledXApps')
                xA = string(pa.enabledXApps(:));
            end
            if isfield(pb,'enabledXApps')
                xB = string(pb.enabledXApps(:));
            end
            xOverlap = intersect(xA, xB);
            if ~isempty(xOverlap)
                c = struct();
                c.policy_a = string(getPolicyId(pa, i));
                c.policy_b = string(getPolicyId(pb, j));
                c.xapp = xOverlap;
                xappConflicts = [xappConflicts; c]; %#ok<AGROW>
            end
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
