function run_xapp_baseline_kpi()

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

    startTime_s = 0.5;

    scenario = ScenarioBuilder(cfg);
    kernel   = RanKernelNR(cfg, scenario);
    ric      = NearRTRIC(cfg, "xappSet", []);

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

    instThr = nan(slotCount,1);
    instDrop = nan(slotCount,1);
    instBler = nan(slotCount,1);
    instPrbUtil = nan(slotCount,1);
    instMeanSinr = nan(slotCount,1);
    instInterf = nan(slotCount,1);

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

        instThr(s) = computeInstantThroughput(kernel.ctx);
        instDrop(s) = computeInstantDrop(kernel.ctx);
        instBler(s) = computeInstantBler(kernel.ctx);
        instPrbUtil(s) = computeInstantPrbUtil(kernel.ctx);
        instMeanSinr(s) = computeInstantMeanSinr(kernel.ctx);
        instInterf(s) = computeInstantInterf(kernel.ctx);

        if mod(s, 200) == 0
            fprintf('[DEBUG][slot=%d][instant] thr=%.2f drop=%.4f bler=%.4f prbUtil=%.3f sinr=%.2f interf=%.2f\n', ...
                s, instThr(s), instDrop(s), instBler(s), instPrbUtil(s), instMeanSinr(s), instInterf(s));
        end
    end

    mask = t_s >= startTime_s;
    if ~any(mask)
        mask = true(size(t_s));
    end

    fprintf('\n===== Baseline KPI Summary (No xApps, t>=%.1fs) =====\n', startTime_s);
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

    if isfield(kernel.ctx.tmp,'kpi')
        fprintf('\n===== Baseline KPI Full Dump =====\n');
        disp(kernel.ctx.tmp.kpi);
    end

    figure('Name','Baseline KPI (No xApps)');
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

    window = 50;
    instThrW = movmean(instThr, window, 'omitnan');
    instDropW = movmean(instDrop, window, 'omitnan');
    instBlerW = movmean(instBler, window, 'omitnan');
    instPrbUtilW = movmean(instPrbUtil, window, 'omitnan');
    instMeanSinrW = movmean(instMeanSinr, window, 'omitnan');
    instInterfW = movmean(instInterf, window, 'omitnan');

    figure('Name','Baseline KPI Instant/Windowed');
    tiledlayout(3,2);

    nexttile;
    plot(t_s, instThr, 'LineWidth', 0.8); hold on;
    plot(t_s, instThrW, 'LineWidth', 1.6);
    title('Instant Throughput (Mbps)'); grid on; legend('instant','window=50','Location','best');

    nexttile;
    plot(t_s, instDrop, 'LineWidth', 0.8); hold on;
    plot(t_s, instDropW, 'LineWidth', 1.6);
    title('Instant Drop Ratio'); grid on; legend('instant','window=50','Location','best');

    nexttile;
    plot(t_s, instBler, 'LineWidth', 0.8); hold on;
    plot(t_s, instBlerW, 'LineWidth', 1.6);
    title('Instant Mean BLER'); grid on; legend('instant','window=50','Location','best');

    nexttile;
    plot(t_s, instPrbUtil, 'LineWidth', 0.8); hold on;
    plot(t_s, instPrbUtilW, 'LineWidth', 1.6);
    title('Instant PRB Util'); grid on; legend('instant','window=50','Location','best');

    nexttile;
    plot(t_s, instMeanSinr, 'LineWidth', 0.8); hold on;
    plot(t_s, instMeanSinrW, 'LineWidth', 1.6);
    title('Instant Mean SINR (dB)'); grid on; legend('instant','window=50','Location','best');

    nexttile;
    plot(t_s, instInterf, 'LineWidth', 0.8); hold on;
    plot(t_s, instInterfW, 'LineWidth', 1.6);
    title('Instant Interference (dBm)'); grid on; legend('instant','window=50','Location','best');
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

function thr = computeInstantThroughput(ctx)
    thr = nan;
    if ~isprop(ctx,'tmp') || ~isstruct(ctx.tmp) || ~isfield(ctx.tmp,'lastServedBitsPerUE')
        fprintf('[WARN][instant] missing ctx.tmp.lastServedBitsPerUE\n');
        return;
    end
    bits = sum(double(ctx.tmp.lastServedBitsPerUE(:)));
    thr = (bits / max(ctx.dt, eps)) / 1e6;
end

function dr = computeInstantDrop(ctx)
    dr = nan;
    if ~isprop(ctx,'scenario') || ~isfield(ctx.scenario,'traffic') || ...
       ~isfield(ctx.scenario.traffic,'model')
        fprintf('[WARN][instant] missing ctx.scenario.traffic.model\n');
        return;
    end
    tm = ctx.scenario.traffic.model;
    if ~isprop(tm,'lastDropThisSlot') || isempty(tm.lastDropThisSlot)
        fprintf('[WARN][instant] missing traffic.lastDropThisSlot\n');
        return;
    end
    droppedBits = double(tm.lastDropThisSlot.bitsTotal);

    servedBits = 0;
    if isprop(ctx,'tmp') && isstruct(ctx.tmp) && isfield(ctx.tmp,'lastServedBitsPerUE')
        servedBits = sum(double(ctx.tmp.lastServedBitsPerUE(:)));
    end
    denom = droppedBits + servedBits;
    if denom <= 0
        dr = 0;
    else
        dr = droppedBits / denom;
    end
end

function b = computeInstantBler(ctx)
    b = nan;
    if isprop(ctx,'tmp') && isstruct(ctx.tmp) && isfield(ctx.tmp,'lastBLERPerUE')
        b = mean(double(ctx.tmp.lastBLERPerUE(:)));
    else
        fprintf('[WARN][instant] missing ctx.tmp.lastBLERPerUE\n');
    end
end

function u = computeInstantPrbUtil(ctx)
    u = nan;
    if isprop(ctx,'lastPRBUsedPerCell_slot') && isprop(ctx,'numPRBPerCell')
        u = mean(double(ctx.lastPRBUsedPerCell_slot(:)) ./ max(double(ctx.numPRBPerCell(:)),1));
    else
        fprintf('[WARN][instant] missing PRB usage fields\n');
    end
end

function s = computeInstantMeanSinr(ctx)
    s = nan;
    if isprop(ctx,'sinr_dB') && ~isempty(ctx.sinr_dB)
        s = mean(double(ctx.sinr_dB(:)));
    else
        fprintf('[WARN][instant] missing ctx.sinr_dB\n');
    end
end

function i = computeInstantInterf(ctx)
    i = nan;
    if isprop(ctx,'tmp') && isstruct(ctx.tmp) && isfield(ctx.tmp,'channel') && ...
       isfield(ctx.tmp.channel,'interference_dBm')
        vals = double(ctx.tmp.channel.interference_dBm(:));
        vals = vals(isfinite(vals));
        if ~isempty(vals)
            i = mean(vals);
        end
    else
        fprintf('[WARN][instant] missing ctx.tmp.channel.interference_dBm\n');
    end
end
