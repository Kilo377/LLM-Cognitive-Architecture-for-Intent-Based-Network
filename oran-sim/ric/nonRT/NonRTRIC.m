classdef NonRTRIC
%NONRTRIC Non-RT RIC (report -> policy -> apply, blocking)

    properties
        cfg

        triggerTime_s
        didTrigger

        reportPath
        policyPath
        policiesPath
        timeout_s
        waitInterval_s

        smoCommand

        lastPolicy
        lastPolicyStamp
        lastConflict
        existingApplied

        debugEnable
        debugEverySlot
    end

    methods
        function obj = NonRTRIC(cfg)

            obj.cfg = cfg;

            obj.triggerTime_s = 1.0;
            if isfield(cfg,'nonRT') && isfield(cfg.nonRT,'triggerTime_s')
                obj.triggerTime_s = cfg.nonRT.triggerTime_s;
            elseif isfield(cfg,'nonRT') && isfield(cfg.nonRT,'periodSlot')
                obj.triggerTime_s = cfg.nonRT.periodSlot * cfg.sim.slotDuration;
            end

            obj.reportPath = "oran-sim/bus_A1/non_rt_report.json";
            if isfield(cfg,'nonRT') && isfield(cfg.nonRT,'reportPath')
                obj.reportPath = string(cfg.nonRT.reportPath);
            end
            obj.reportPath = obj.resolvePath(obj.reportPath);

            obj.policyPath = "oran-sim/bus_A1/non_rt_policy.json";
            if isfield(cfg,'nonRT') && isfield(cfg.nonRT,'policyPath')
                obj.policyPath = string(cfg.nonRT.policyPath);
            end
            obj.policyPath = obj.resolvePath(obj.policyPath);

            obj.policiesPath = "oran-sim/bus_A1/existing_policys.json";
            if isfield(cfg,'nonRT') && isfield(cfg.nonRT,'policiesPath')
                obj.policiesPath = string(cfg.nonRT.policiesPath);
            end
            obj.policiesPath = obj.resolvePath(obj.policiesPath);

            obj.timeout_s = 120;
            if isfield(cfg,'nonRT') && isfield(cfg.nonRT,'timeout_s')
                obj.timeout_s = cfg.nonRT.timeout_s;
            end

            obj.waitInterval_s = 0.5;
            if isfield(cfg,'nonRT') && isfield(cfg.nonRT,'waitInterval_s')
                obj.waitInterval_s = cfg.nonRT.waitInterval_s;
            end

            obj.smoCommand = "";
            if isfield(cfg,'nonRT') && isfield(cfg.nonRT,'smoCommand')
                obj.smoCommand = string(cfg.nonRT.smoCommand);
            end

            obj.didTrigger = false;
            obj.lastPolicy = struct();
            obj.lastPolicyStamp = 0;
            obj.lastConflict = struct();
            obj.existingApplied = false;

            obj.debugEnable = false;
            if isfield(cfg,'debug') && isfield(cfg.debug,'enableNonRT')
                obj.debugEnable = logical(cfg.debug.enableNonRT);
            end

            obj.debugEverySlot = 50;
            if isfield(cfg,'debug') && isfield(cfg.debug,'nonRTEvery')
                obj.debugEverySlot = cfg.debug.nonRTEvery;
            end

            obj.clearStaleFiles();
            fprintf('[Non-RT RIC] Initialized triggerTime_s=%.3f\n', obj.triggerTime_s);
        end

        function [obj, ric, info] = step(obj, ctx, ric)

            slot = 0;
            if isprop(ctx,'slot')
                slot = ctx.slot;
            elseif isprop(ctx,'state') && isfield(ctx.state,'time')
                slot = ctx.state.time.slot;
            end

            info = struct();
            info.slot = slot;
            info.didTick = false;
            info.policyApplied = false;
            info.policySource = "none";

            if obj.debugEnable && obj.shouldPrint(slot)
                fprintf('[Non-RT RIC] slot=%d t_s=%.3f didTrigger=%d\n', ...
                    slot, obj.getTime(ctx), obj.didTrigger);
            end

            if obj.didTrigger
                return;
            end

            if ~obj.existingApplied
                [obj, ric, info] = obj.applyExistingPolicies(ctx, ric, info);
            end

            if obj.getTime(ctx) < obj.triggerTime_s
                return;
            end

            if obj.debugEnable
                fprintf('[Non-RT RIC] trigger reached at t_s=%.3f (slot=%d)\n', ...
                    obj.getTime(ctx), slot);
            end

            report = obj.buildReport(ctx, ric);
            obj.writeReport(report);

            if obj.debugEnable
                fprintf('[Non-RT RIC] waiting policy: %s\n', char(obj.policyPath));
            end

            if strlength(obj.smoCommand) > 0
                if obj.debugEnable
                    fprintf('[Non-RT RIC] invoke SMO: %s\n', char(obj.smoCommand));
                end
                [status, out] = system(char(obj.smoCommand));
                if obj.debugEnable
                    fprintf('[Non-RT RIC] SMO status=%d\n', status);
                    if ~isempty(out)
                        fprintf('%s\n', out);
                    end
                end
            end
            [policy, status] = obj.waitPolicy(report.time.slot);

            if strcmp(status, "ok")
                [policy, valid] = obj.normalizePolicy(policy);
                if valid
                    [mergedXApps, mergedKpiFocus, conflicts] = obj.handlePolicies(report, policy);
                    obj.reportConflicts(conflicts);

                    mergedPolicy = struct();
                    mergedPolicy.enabledXApps = mergedXApps;
                    mergedPolicy.kpi_focus = mergedKpiFocus;

                    ric = ric.setPolicy(mergedPolicy);
                    obj.lastPolicy = mergedPolicy;
                    obj.lastPolicyStamp = obj.lastPolicyStamp + 1;
                    info.policyApplied = true;
                    info.policySource = "python";
                else
                    info.policySource = "invalid";
                end
            elseif strcmp(status, "timeout")
                if ~isempty(fieldnames(obj.lastPolicy))
                    ric = ric.setPolicy(obj.lastPolicy);
                    info.policyApplied = true;
                    info.policySource = "cached";
                else
                    info.policySource = "timeout";
                end
            else
                info.policySource = status;
            end

            obj.didTrigger = true;
            info.didTick = true;

            if obj.debugEnable
                fprintf('[Non-RT RIC] slot=%d tick=1 policySource=%s\n', slot, info.policySource);
            end
        end
    end

    methods (Access = private)
        function report = buildReport(obj, ctx, ric)

            report = struct();

            report.meta = struct();
            report.meta.schemaVersion = "1.0";
            report.meta.generatedAt = obj.utcNow();

            report.time = struct();
            report.time.slot = obj.getSlot(ctx);
            report.time.time_s = obj.getTime(ctx);

            report.policy = struct();
            report.policy.current = obj.getCurrentPolicy(ric);

            report.control = struct();
            report.control.baseline = obj.getBaseline(ctx);
            report.control.ctrl = obj.getCtrl(ctx);

            report.state = obj.getState(ctx);

            report.kpi = struct();
            report.kpi.instant = obj.getInstantKpi(ctx);
            report.kpi.accumulated = obj.getAccumulatedKpi(ctx);

            report.xappPool = obj.getXAppPool(ric);
        end

        function writeReport(obj, report)

            obj.ensureParentDir(obj.reportPath);
            obj.ensureParentDir(obj.policyPath);

            if exist(obj.policyPath, 'file') == 2
                delete(obj.policyPath);
            end

            obj.writeJson(report, obj.reportPath);

            if obj.debugEnable
                fprintf('[Non-RT RIC] report written: %s\n', char(obj.reportPath));
            end
        end

        function clearStaleFiles(obj)

            if exist(obj.reportPath, 'file') == 2
                delete(obj.reportPath);
            end
            if exist(obj.policyPath, 'file') == 2
                delete(obj.policyPath);
            end
        end

        function [mergedXApps, mergedKpiFocus, conflicts] = handlePolicies(obj, report, newPolicy)

            policies = obj.loadExistingPolicies();

            newEntry = struct();
            newEntry.policy_id = "policy_" + string(report.time.slot);
            newEntry.enabledXApps = obj.normalizeStringList(newPolicy.enabledXApps);
            newEntry.kpi_focus = string.empty(1,0);
            newEntry.status = "active";
            newEntry.created_at = string(report.meta.generatedAt);

            if isfield(newPolicy,'kpi_focus')
                newEntry.kpi_focus = obj.normalizeStringList(newPolicy.kpi_focus);
            end

            policies = [policies; newEntry]; %#ok<AGROW>

            [mergedXApps, mergedKpiFocus, conflicts] = policy_mitigation_a1(policies);

            obj.saveExistingPolicies(policies);
        end

        function [obj, ric, info] = applyExistingPolicies(obj, ctx, ric, info)

            obj.existingApplied = true;
            policies = obj.loadExistingPolicies();
            if isempty(policies)
                return;
            end

            [mergedXApps, mergedKpiFocus, conflicts] = policy_mitigation_a1(policies);
            obj.reportConflicts(conflicts);

            if isempty(mergedXApps) && isempty(mergedKpiFocus)
                return;
            end

            mergedPolicy = struct();
            mergedPolicy.enabledXApps = mergedXApps;
            mergedPolicy.kpi_focus = mergedKpiFocus;

            ric = ric.setPolicy(mergedPolicy);
            obj.lastPolicy = mergedPolicy;
            obj.lastPolicyStamp = obj.lastPolicyStamp + 1;
            info.policyApplied = true;
            info.policySource = "existing";

            if obj.debugEnable
                fprintf('[Non-RT RIC] applied existing policy at slot=%d\n', obj.getSlot(ctx));
            end
        end

        function policies = loadExistingPolicies(obj)

            policies = struct('policy_id', string.empty(0,1), ...
                'enabledXApps', [], 'kpi_focus', [], 'status', string.empty(0,1), ...
                'created_at', string.empty(0,1));

            if exist(obj.policiesPath, 'file') ~= 2
                return;
            end

            try
                raw = fileread(obj.policiesPath);
                data = jsondecode(raw);
                if isfield(data,'policies')
                    data = data.policies;
                end
                if isstruct(data)
                    policies = data;
                end
            catch
            end
        end

        function saveExistingPolicies(obj, policies)

            obj.ensureParentDir(obj.policiesPath);
            out = struct();
            out.policies = policies;
            obj.writeJson(out, obj.policiesPath);
        end

        function reportConflicts(obj, conflicts)

            obj.lastConflict = conflicts;

            if isempty(conflicts)
                if obj.debugEnable
                    fprintf('[Non-RT RIC] conflict report: none\n');
                end
                return;
            end

            if isfield(conflicts,'kpi') && ~isempty(conflicts.kpi)
                fprintf('[Non-RT RIC] KPI conflicts:\n');
                for i = 1:numel(conflicts.kpi)
                    c = conflicts.kpi(i);
                    fprintf('  kpi=%s winner=%s candidates=%s\n', ...
                        c.kpi, c.winner, strjoin(cellstr(c.policies(:)), ','));
                end
            end

            if isfield(conflicts,'xapp') && ~isempty(conflicts.xapp)
                fprintf('[Non-RT RIC] xApp conflicts:\n');
                for i = 1:numel(conflicts.xapp)
                    c = conflicts.xapp(i);
                    fprintf('  xapp=%s winner=%s candidates=%s\n', ...
                        c.xapp, c.winner, strjoin(cellstr(c.policies(:)), ','));
                end
            end
        end

        function writeJson(~, data, path)

            payload = jsonencode(data);

            fid = fopen(path, 'w');
            if fid < 0
                error('NonRTRIC:WriteFailed', 'Failed to open report file: %s', path);
            end

            try
                fwrite(fid, payload, 'char');
            catch
                fclose(fid);
                rethrow(lasterror); %#ok<LERR>
            end

            fclose(fid);
        end

        function [policy, status] = waitPolicy(obj, requestSlot)

            policy = struct();
            status = "timeout";

            tStart = tic;

            while true
                if exist(obj.policyPath, 'file') == 2
                    try
                        raw = readstruct(obj.policyPath, "FileType", "json");
                        delete(obj.policyPath);
                        policy = obj.extractPolicy(raw, requestSlot);
                        status = "ok";
                    catch
                        status = "invalid";
                    end
                    break;
                end

                if obj.timeout_s > 0 && toc(tStart) > obj.timeout_s
                    status = "timeout";
                    break;
                end

                pause(obj.waitInterval_s);
            end
        end

        function [policy, valid] = normalizePolicy(obj, policy)

            valid = false;

            if ~isstruct(policy)
                return;
            end

            if ~isfield(policy,'enabledXApps')
                return;
            end

            policy.enabledXApps = obj.normalizeStringList(policy.enabledXApps);
            valid = true;
        end

        function policy = extractPolicy(~, raw, requestSlot)

            if isfield(raw,'policy')
                policy = raw.policy;
            else
                policy = raw;
            end

            if isfield(policy,'validFromSlot')
                try
                    if requestSlot < policy.validFromSlot
                        policy = struct('enabledXApps', string.empty(1,0));
                    end
                catch
                end
            end
        end

        function s = getCurrentPolicy(~, ric)

            s = struct('enabledXApps', string.empty(1,0), 'stamp', 0, 'source', 'near-RT');

            if isprop(ric,'policy') && isfield(ric.policy,'enabledXApps')
                s.enabledXApps = string(ric.policy.enabledXApps);
            end
            if isprop(ric,'policyStamp')
                s.stamp = ric.policyStamp;
            end
        end

        function b = getBaseline(~, ctx)

            b = struct();
            if isprop(ctx,'baseline')
                if isfield(ctx.baseline,'bandwidthHzPerCell')
                    b.bandwidthHzPerCell = ctx.baseline.bandwidthHzPerCell;
                end
                if isfield(ctx.baseline,'txPowerCell_dBm')
                    b.txPowerCell_dBm = ctx.baseline.txPowerCell_dBm;
                end
                if isfield(ctx.baseline,'numPRBPerCell')
                    b.numPRBPerCell = ctx.baseline.numPRBPerCell;
                end
                if isfield(ctx.baseline,'noiseFigure_dB')
                    b.noiseFigure_dB = ctx.baseline.noiseFigure_dB;
                end
            end
        end

        function c = getCtrl(~, ctx)

            c = struct();
            if isprop(ctx,'ctrl')
                c = ctx.ctrl;
            end
        end

        function s = getState(~, ctx)

            s = struct();
            if isprop(ctx,'state')
                s = ctx.state;
            end
        end

        function k = getInstantKpi(~, ctx)

            k = struct();

            if ~isprop(ctx,'tmp') || ~isfield(ctx.tmp,'kpi')
                return;
            end

            tk = ctx.tmp.kpi;

            if isfield(tk,'capacity') && isfield(tk.capacity,'throughput_Mbps_total')
                k.throughput_Mbps_total = tk.capacity.throughput_Mbps_total;
            end
            if isfield(tk,'reliability') && isfield(tk.reliability,'dropRatio')
                k.dropRatio = tk.reliability.dropRatio;
            end
            if isfield(tk,'reliability') && isfield(tk.reliability,'meanBLER')
                k.meanBLER = tk.reliability.meanBLER;
            end
            if isfield(tk,'resource') && isfield(tk.resource,'prbUtilMean')
                k.prbUtilMean = tk.resource.prbUtilMean;
            end
            if isfield(tk,'system') && isfield(tk.system,'congestionIndex')
                k.congestionIndex = tk.system.congestionIndex;
            end
            if isfield(tk,'efficiency') && isfield(tk.efficiency,'energy_J_total')
                k.energy_J_total = tk.efficiency.energy_J_total;
            end
            if isfield(tk,'efficiency') && isfield(tk.efficiency,'bitPerJ')
                k.bitPerJ = tk.efficiency.bitPerJ;
            end
        end

        function k = getAccumulatedKpi(~, ctx)

            k = struct();

            if isprop(ctx,'accThroughputBitPerUE')
                k.throughputBitPerUE = ctx.accThroughputBitPerUE;
            end
            if isprop(ctx,'accDroppedTotal')
                k.dropTotal = ctx.accDroppedTotal;
            end
            if isprop(ctx,'accDroppedURLLC')
                k.dropURLLC = ctx.accDroppedURLLC;
            end
            if isprop(ctx,'accHOCount')
                k.handoverCount = ctx.accHOCount;
            end
            if isprop(ctx,'accRLFCount')
                k.rlfCount = ctx.accRLFCount;
            end
            if isprop(ctx,'accEnergyJPerCell')
                k.energyJPerCell = ctx.accEnergyJPerCell;
            end
        end

        function pool = getXAppPool(~, ric)

            pool = [];
            if isprop(ric,'xappRegistry') && ~isempty(ric.xappRegistry)
                pool = ric.xappRegistry.getXApps();
            end
        end

        function ensureParentDir(~, path)

            p = char(path);
            if ~isfolder(fileparts(p))
                mkdir(fileparts(p));
            end
        end

        function slot = getSlot(~, ctx)

            slot = 0;
            if isprop(ctx,'slot')
                slot = ctx.slot;
            elseif isprop(ctx,'state') && isfield(ctx.state,'time')
                slot = ctx.state.time.slot;
            end
        end

        function t = getTime(~, ctx)

            t = 0;
            if isprop(ctx,'slot') && isprop(ctx,'dt')
                t = ctx.slot * ctx.dt;
                return;
            end
            if isprop(ctx,'state') && isfield(ctx.state,'time')
                t = ctx.state.time.t_s;
            end
        end

        function tf = shouldPrint(obj, slot)

            if obj.debugEverySlot <= 1
                tf = true;
                return;
            end

            if slot == 0
                tf = true;
                return;
            end

            tf = mod(slot, obj.debugEverySlot) == 0;
        end

        function ts = utcNow(~)

            d = datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''');
            ts = char(d);
        end

        function out = normalizeStringList(~, value)

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

        function p = resolvePath(obj, p)

            if isstring(p)
                p = char(p);
            end

            if obj.isAbsolutePath(p)
                return;
            end

            repoRoot = obj.getRepoRoot();
            p = fullfile(repoRoot, p);
        end

        function tf = isAbsolutePath(~, p)

            if startsWith(p, filesep)
                tf = true;
                return;
            end

            tf = ~isempty(regexp(p, '^[A-Za-z]:[\\/]', 'once'));
        end

        function root = getRepoRoot(~)

            here = fileparts(mfilename('fullpath'));
            oranDir = fileparts(fileparts(here));
            root = fileparts(oranDir);
        end
    end
end
