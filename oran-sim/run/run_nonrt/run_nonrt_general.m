function run_nonrt_general()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    rootDir = setup_path();

    cfg = default_config();
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 2000;

    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    cfg.nonRT.triggerTime_s = 0.5;
    cfg.nonRT.timeout_s = 30;
    cfg.debug.enableNonRT = true;
    cfg.debug.nonRTEvery = 100;
    cfg.debug.enableXApp = true;

    startTime_s = 0.5;

    scenario = ScenarioBuilder(cfg);
    kernel   = RanKernelNR(cfg, scenario);
    ric      = NearRTRIC(cfg, "xappSet", []);
    nonrt    = NonRTRIC(cfg);

    slotCount = cfg.sim.slotPerEpisode;
    t_s = zeros(slotCount,1);

    thr = nan(slotCount,1);
    drop = nan(slotCount,1);
    bler = nan(slotCount,1);
    prbUtil = nan(slotCount,1);
    cong = nan(slotCount,1);
    bitj = nan(slotCount,1);
    meanSinr = nan(slotCount,1);
    p10Sinr = nan(slotCount,1);
    p50Sinr = nan(slotCount,1);
    p90Sinr = nan(slotCount,1);
    fairness = nan(slotCount,1);
    top10 = nan(slotCount,1);
    interf = nan(slotCount,1);
    energy = nan(slotCount,1);

    policyAppliedSlot = nan;
    policyXApps = string.empty(1,0);
    policyKpiFocus = string.empty(1,0);

    for s = 1:slotCount
        state = kernel.ctx.state;
        [ric, action, ~] = ric.step(state);
        kernel = kernel.step(action);

        t_s(s) = kernel.ctx.slot * kernel.ctx.dt;
        if isfield(kernel.ctx.tmp,'kpi')
            kpi = kernel.ctx.tmp.kpi;
            thr(s) = getField(kpi, "capacity.throughput_Mbps_total", nan);
            fairness(s) = getField(kpi, "capacity.jainFairness", nan);
            top10(s) = getField(kpi, "capacity.top10Share", nan);

            bler(s) = getField(kpi, "reliability.meanBLER", nan);
            drop(s) = getField(kpi, "reliability.dropRatio", nan);

            bitj(s) = getField(kpi, "efficiency.bitPerJ", nan);
            energy(s) = getField(kpi, "efficiency.energy_J_total", nan);

            prbUtil(s) = getField(kpi, "resource.prbUtilMean", nan);
            interf(s) = getField(kpi, "resource.meanInterference_dBm", nan);

            meanSinr(s) = getField(kpi, "phy.meanSINR_dB", nan);
            p10Sinr(s) = getField(kpi, "phy.p10SINR_dB", nan);
            p50Sinr(s) = getField(kpi, "phy.p50SINR_dB", nan);
            p90Sinr(s) = getField(kpi, "phy.p90SINR_dB", nan);

            cong(s) = getField(kpi, "system.congestionIndex", nan);
        end

        if cfg.debug.enableNonRT && mod(kernel.ctx.slot, cfg.debug.nonRTEvery) == 0
            fprintf('[RUN] slot=%d t_s=%.3f\n', kernel.ctx.slot, kernel.ctx.slot * kernel.ctx.dt);
        end

        [nonrt, ric, info] = nonrt.step(kernel.ctx, ric);
        if info.policyApplied && isnan(policyAppliedSlot)
            policyAppliedSlot = kernel.ctx.slot;
            [policyXApps, policyKpiFocus] = readPolicySummary(nonrt, ric);
            fprintf('\n===== Non-RT Policy Selection =====\n');
            fprintf('Applied slot: %d\n', policyAppliedSlot);
            fprintf('Enabled xApps: %s\n', mat2str(policyXApps));
            fprintf('KPI focus: %s\n', mat2str(policyKpiFocus));
        end
    end

    mask = t_s >= startTime_s;
    if ~any(mask)
        mask = true(size(t_s));
    end

    fprintf('\n===== Non-RT General KPI Summary (t>=%.1fs) =====\n', startTime_s);
    fprintf('Throughput (Mbps): %.2f\n', mean(thr(mask), 'omitnan'));
    fprintf('Fairness (Jain): %.3f\n', mean(fairness(mask), 'omitnan'));
    fprintf('Top10Share: %.3f\n', mean(top10(mask), 'omitnan'));
    fprintf('DropRatio: %.4f\n', mean(drop(mask), 'omitnan'));
    fprintf('Mean BLER: %.4f\n', mean(bler(mask), 'omitnan'));
    fprintf('PRB Util Mean: %.3f\n', mean(prbUtil(mask), 'omitnan'));
    fprintf('Congestion Index: %.3f\n', mean(cong(mask), 'omitnan'));
    fprintf('Bit/J: %.1f\n', mean(bitj(mask), 'omitnan'));
    fprintf('Energy (J): %.1f\n', mean(energy(mask), 'omitnan'));
    fprintf('Mean Interference (dBm): %.2f\n', mean(interf(mask), 'omitnan'));
    fprintf('SINR mean/p10/p50/p90 (dB): %.2f / %.2f / %.2f / %.2f\n', ...
        mean(meanSinr(mask), 'omitnan'), mean(p10Sinr(mask), 'omitnan'), ...
        mean(p50Sinr(mask), 'omitnan'), mean(p90Sinr(mask), 'omitnan'));

    printLastConflict(ric);
    printNonRTConflict(nonrt);

    if isfield(kernel.ctx.tmp,'kpi')
        fprintf('\n===== Non-RT KPI Full Dump =====\n');
        disp(kernel.ctx.tmp.kpi);
    end

    figure('Name','Non-RT General KPI');
    tiledlayout(4,3);

    nexttile; plot(t_s, thr, 'LineWidth', 1.2); title('Throughput (Mbps)'); grid on;
    nexttile; plot(t_s, drop, 'LineWidth', 1.2); title('Drop Ratio'); grid on;
    nexttile; plot(t_s, bler, 'LineWidth', 1.2); title('Mean BLER'); grid on;

    nexttile; plot(t_s, fairness, 'LineWidth', 1.2); title('Jain Fairness'); grid on;
    nexttile; plot(t_s, top10, 'LineWidth', 1.2); title('Top10 Share'); grid on;
    nexttile; plot(t_s, prbUtil, 'LineWidth', 1.2); title('PRB Util'); grid on;

    nexttile; plot(t_s, cong, 'LineWidth', 1.2); title('Congestion Index'); grid on;
    nexttile; plot(t_s, bitj, 'LineWidth', 1.2); title('Bit/J'); grid on;
    nexttile; plot(t_s, energy, 'LineWidth', 1.2); title('Energy (J)'); grid on;

    nexttile; plot(t_s, interf, 'LineWidth', 1.2); title('Interference (dBm)'); grid on;
    nexttile; plot(t_s, meanSinr, 'LineWidth', 1.2); title('Mean SINR (dB)'); grid on;
    nexttile; plot(t_s, p10Sinr, 'LineWidth', 1.2); title('p10 SINR (dB)'); grid on;

    if ~isnan(policyAppliedSlot)
        addTriggerLine(cfg.nonRT.triggerTime_s);
    end
end

function v = getField(s, path, defaultValue)

    v = defaultValue;
    if ~isstruct(s)
        return;
    end

    parts = split(string(path), ".");
    parts = cellstr(parts);
    cur = s;
    for i = 1:numel(parts)
        key = parts{i};
        if ~isfield(cur, key)
            return;
        end
        cur = cur.(key);
    end

    if isempty(cur)
        return;
    end

    if isnumeric(cur)
        if isscalar(cur)
            v = double(cur);
        else
            v = double(cur(1));
        end
    else
        v = defaultValue;
    end
end

function printLastConflict(ric)
    if isprop(ric,'lastConflict') && ~isempty(ric.lastConflict)
        lc = ric.lastConflict;
        if isfield(lc,'domain') && lc.domain == "handover"
            fprintf('\n===== Last Handover Conflict =====\n');
            if isfield(lc,'slot')
                fprintf('slot=%d\n', lc.slot);
            end
            if isfield(lc,'field')
                fprintf('field=handover.%s\n', lc.field);
            end
            if isfield(lc,'mergeMode')
                fprintf('mergeMode=%s\n', lc.mergeMode);
            end
            if isfield(lc,'sources')
                fprintf('sources=%s\n', mat2str(string(lc.sources)));
            end
            if isfield(lc,'values')
                try
                    fprintf('values=%s\n', mat2str(lc.values));
                catch
                    fprintf('values=[%d items]\n', numel(lc.values));
                end
            end
        end
    else
        fprintf('\nNo handover conflicts detected.\n');
    end
end

function [xapps, kpiFocus] = readPolicySummary(nonrt, ric)

    xapps = string.empty(1,0);
    kpiFocus = string.empty(1,0);

    if isprop(ric,'pendingPolicy') && isfield(ric.pendingPolicy,'enabledXApps')
        xapps = normalizeStringList(ric.pendingPolicy.enabledXApps);
    elseif isprop(ric,'policy') && isfield(ric.policy,'enabledXApps')
        xapps = normalizeStringList(ric.policy.enabledXApps);
    end

    if ~isprop(nonrt,'policiesPath')
        return;
    end

    try
        raw = fileread(char(nonrt.policiesPath));
        data = jsondecode(raw);
        if isfield(data,'policies')
            data = data.policies;
        end
        if isstruct(data) && ~isempty(data)
            last = data(end);
            if isfield(last,'kpi_focus')
                kpiFocus = normalizeStringList(last.kpi_focus);
            end
        end
    catch
    end
end

function printNonRTConflict(nonrt)
    if isprop(nonrt,'lastConflict') && ~isempty(nonrt.lastConflict)
        lc = nonrt.lastConflict;
        if isfield(lc,'kpi') && ~isempty(lc.kpi)
            fprintf('\n===== Non-RT KPI Conflicts =====\n');
            for i = 1:numel(lc.kpi)
                c = lc.kpi(i);
                fprintf('kpi=%s winner=%s candidates=%s\n', ...
                    c.kpi, c.winner, strjoin(cellstr(c.policies(:)), ','));
            end
        end
        if isfield(lc,'xapp') && ~isempty(lc.xapp)
            fprintf('\n===== Non-RT xApp Conflicts =====\n');
            for i = 1:numel(lc.xapp)
                c = lc.xapp(i);
                fprintf('xapp=%s winner=%s candidates=%s\n', ...
                    c.xapp, c.winner, strjoin(cellstr(c.policies(:)), ','));
            end
        end
    else
        fprintf('\nNo Non-RT conflicts detected.\n');
    end
end

function addTriggerLine(t)

    ax = findall(gcf, 'Type', 'axes');
    for i = 1:numel(ax)
        xline(ax(i), t, '--r', 'Trigger');
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
