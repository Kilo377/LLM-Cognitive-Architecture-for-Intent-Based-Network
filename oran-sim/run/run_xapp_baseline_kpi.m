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

    cfg.nonRT.triggerTime_s = 1.0;
    cfg.nonRT.timeout_s = 30;
    cfg.debug.enableNonRT = true;
    cfg.debug.nonRTEvery = 100;

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
    end

    fprintf('\n===== Baseline KPI Summary (No xApps) =====\n');
    fprintf('Throughput (Mbps): %.2f\n', mean(thr, 'omitnan'));
    fprintf('Fairness (Jain): %.3f\n', mean(fairness, 'omitnan'));
    fprintf('Top10Share: %.3f\n', mean(top10, 'omitnan'));
    fprintf('DropRatio: %.4f\n', mean(drop, 'omitnan'));
    fprintf('Mean BLER: %.4f\n', mean(bler, 'omitnan'));
    fprintf('PRB Util Mean: %.3f\n', mean(prbUtil, 'omitnan'));
    fprintf('Congestion Index: %.3f\n', mean(cong, 'omitnan'));
    fprintf('Bit/J: %.1f\n', mean(bitj, 'omitnan'));
    fprintf('Energy (J): %.1f\n', mean(energy, 'omitnan'));
    fprintf('Mean Interference (dBm): %.2f\n', mean(interf, 'omitnan'));
    fprintf('SINR mean/p10/p50/p90 (dB): %.2f / %.2f / %.2f / %.2f\n', ...
        mean(meanSinr, 'omitnan'), mean(p10Sinr, 'omitnan'), ...
        mean(p50Sinr, 'omitnan'), mean(p90Sinr, 'omitnan'));

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
