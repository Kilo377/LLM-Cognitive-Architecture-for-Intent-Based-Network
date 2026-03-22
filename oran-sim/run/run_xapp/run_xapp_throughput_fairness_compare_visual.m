function run_xapp_throughput_fairness_compare_visual()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    rootDir = setup_path();

    cfg = default_config();
    cfg = applyHighLoad(cfg);
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 800;
    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    cases = {
        "baseline", [];
        "throughput_only", ["xapp_throughput_booster"];
        "fairness_only", ["xapp_fairness_scheduler"];
        "throughput_plus_fairness", ["xapp_throughput_booster", "xapp_fairness_scheduler"]
    };

    results = struct();

    for ci = 1:size(cases,1)
        name = cases{ci,1};
        xset = cases{ci,2};

        fprintf("\n=== xApp Compare Case: %s ===\n", name);

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);
        ric      = NearRTRIC(cfg, "xappSet", xset);

        for s = 1:cfg.sim.slotPerEpisode
            state = kernel.ctx.state;
            [ric, action, ~] = ric.step(state);
            kernel = kernel.step(action);
        end

        results.(name) = summarizeKpi(kernel.ctx.tmp.kpi);
    end

    printSummary(results);
    plotSummary(results, cases(:,1));
end

function cfg = applyHighLoad(cfg)

    cfg.scenario.numUE = max(80, cfg.scenario.numUE);

    if ~isfield(cfg,'traffic')
        cfg.traffic = struct();
    end

    cfg.traffic.overloadFactor = 2.5;
    cfg.traffic.silentRatio = 0.05;
    cfg.traffic.heavyRatio  = 0.40;
    cfg.traffic.heavyMultiplierE = 10.0;
    cfg.traffic.heavyMultiplierU = 4.0;
    cfg.traffic.heavyMultiplierM = 5.0;
    cfg.traffic.enableBurst = true;

    cfg.traffic.hotspot.enable = true;
    cfg.traffic.hotspot.cellId = 1;
    cfg.traffic.hotspot.heavyRatioInHot = 0.85;
    cfg.traffic.hotspot.heavyRatioOutHot = 0.05;
end

function out = summarizeKpi(kpi)

    out = struct();
    out.throughput_Mbps = kpi.capacity.throughput_Mbps_total;
    out.fairness = kpi.capacity.jainFairness;
    out.top10Share = kpi.capacity.top10Share;
    out.dropRatio = kpi.reliability.dropRatio;
    out.meanBLER = kpi.reliability.meanBLER;
end

function printSummary(results)

    names = fieldnames(results);

    fprintf("\n===== xApp Throughput/Fairness KPI Summary =====\n");
    fprintf("Case                    Thr(Mbps)  Fairness  Top10Share  DropRatio  BLER\n");

    for i = 1:numel(names)
        r = results.(names{i});
        fprintf("%-22s %9.2f  %8.3f  %9.3f  %8.4f  %7.4f\n", ...
            names{i}, r.throughput_Mbps, r.fairness, r.top10Share, r.dropRatio, r.meanBLER);
    end
end

function plotSummary(results, caseNames)

    n = numel(caseNames);
    thr = zeros(n,1);
    fair = zeros(n,1);
    top10 = zeros(n,1);
    drop = zeros(n,1);

    for i = 1:n
        r = results.(caseNames{i});
        thr(i) = r.throughput_Mbps;
        fair(i) = r.fairness;
        top10(i) = r.top10Share;
        drop(i) = r.dropRatio;
    end

    figure('Name','xApp Throughput/Fairness Compare');

    subplot(2,2,1);
    bar(thr);
    title('Throughput (Mbps)');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,2,2);
    bar(fair);
    title('Jain Fairness');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,2,3);
    bar(top10);
    title('Top10 Share');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,2,4);
    bar(drop);
    title('Drop Ratio');
    grid on;
    set(gca,'XTickLabel',caseNames);
end
