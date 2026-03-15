function run_xapp_fairness_efficiency_conflict_visual()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    rootDir = setup_path();

    cfg = default_config();
    cfg = applyHighLoad(cfg);
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 250;
    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    fixedInterf = 6.0;

    cases = {
        "baseline", [];
        "load_balancing_only", ["xapp_load_balancing"];
        "efficiency_only", ["xapp_throughput_efficiency"];
        "load_plus_efficiency", ["xapp_load_balancing", "xapp_throughput_efficiency"]
    };

    results = struct();

    for ci = 1:size(cases,1)
        name = cases{ci,1};
        xset = cases{ci,2};

        fprintf("\n=== xApp Fairness/Efficiency Case: %s ===\n", name);

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);
        ric      = NearRTRIC(cfg, "xappSet", xset);

        kernel.ctx.ctrl.interferenceCouplingFactor = fixedInterf;

        for s = 1:cfg.sim.slotPerEpisode
            state = kernel.ctx.state;
            [ric, action, ~] = ric.step(state);
            kernel = kernel.step(action);
        end

        results.(name) = summarizeKpi(kernel.ctx.tmp.kpi);
    end

    printSummary(results, fixedInterf);
    plotSummary(results, cases(:,1));
end

function cfg = applyHighLoad(cfg)

    cfg.scenario.numUE = max(60, cfg.scenario.numUE);

    if ~isfield(cfg,'traffic')
        cfg.traffic = struct();
    end

    cfg.traffic.overloadFactor = 2.0;
    cfg.traffic.silentRatio = 0.05;
    cfg.traffic.heavyRatio  = 0.35;
    cfg.traffic.heavyMultiplierE = 8.0;
    cfg.traffic.heavyMultiplierU = 3.5;
    cfg.traffic.heavyMultiplierM = 4.0;
    cfg.traffic.enableBurst = true;

    cfg.traffic.hotspot.enable = true;
    cfg.traffic.hotspot.cellId = 1;
    cfg.traffic.hotspot.heavyRatioInHot = 0.75;
    cfg.traffic.hotspot.heavyRatioOutHot = 0.10;
end

function out = summarizeKpi(kpi)

    out = struct();
    out.throughput_Mbps = kpi.capacity.throughput_Mbps_total;
    out.dropRatio = kpi.reliability.dropRatio;
    out.meanBLER = kpi.reliability.meanBLER;
    out.jainFairness = kpi.capacity.jainFairness;
    out.top10Share = kpi.capacity.top10Share;
    out.bitPerJ = kpi.efficiency.bitPerJ;

    if isfield(kpi,'phy')
        out.p10SINR_dB = kpi.phy.p10SINR_dB;
        out.p50SINR_dB = kpi.phy.p50SINR_dB;
    else
        out.p10SINR_dB = 0;
        out.p50SINR_dB = 0;
    end
end

function printSummary(results, fixedInterf)

    names = fieldnames(results);

    fprintf("\n===== xApp Fairness/Efficiency KPI Summary =====\n");
    fprintf("Fixed: interferenceCouplingFactor=%.2f\n", fixedInterf);
    fprintf("Case                          Thr(Mbps)  DropRatio  BLER     Jain     Top10   p10SINR  p50SINR  Bit/J\n");

    for i = 1:numel(names)
        r = results.(names{i});
        fprintf("%-28s %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %7.2f  %7.2f  %7.1f\n", ...
            names{i}, r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.jainFairness, r.top10Share, r.p10SINR_dB, r.p50SINR_dB, r.bitPerJ);
    end
end

function plotSummary(results, caseNames)

    n = numel(caseNames);
    thr = zeros(n,1);
    jain = zeros(n,1);
    top10 = zeros(n,1);
    bler = zeros(n,1);
    drop = zeros(n,1);

    for i = 1:n
        r = results.(caseNames{i});
        thr(i) = r.throughput_Mbps;
        jain(i) = r.jainFairness;
        top10(i) = r.top10Share;
        bler(i) = r.meanBLER;
        drop(i) = r.dropRatio;
    end

    figure('Name','xApp Fairness/Efficiency Conflict');

    subplot(2,3,1);
    bar(thr);
    title('Throughput (Mbps)');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,3,2);
    bar(jain);
    title('Jain Fairness');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,3,3);
    bar(top10);
    title('Top10 Share');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,3,4);
    bar(bler);
    title('BLER');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,3,5);
    bar(drop);
    title('Drop Ratio');
    grid on;
    set(gca,'XTickLabel',caseNames);
end
