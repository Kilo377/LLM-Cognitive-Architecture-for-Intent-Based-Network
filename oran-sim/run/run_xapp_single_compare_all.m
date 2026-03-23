function run_xapp_single_compare_all()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    rootDir = setup_path();

    cfg = default_config();
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 2000;
    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    xapps = [ ...
        "xapp_capacity_booster"; ...
        "xapp_drop_reducer"; ...
        "xapp_fairness_scheduler"; ...
        "xapp_fairness_no_thr_loss"; ...
        "xapp_fairness_no_drop_loss"; ...
        "xapp_interference_mitigator"; ...
        "xapp_mobility_balancer"; ...
        "xapp_stability_guard"; ...
        "xapp_throughput_maximizer" ...
    ];

    results = struct();

    results.baseline = runCase(cfg, [], "baseline");

    for i = 1:numel(xapps)
        xid = xapps(i);
        results.(xid) = runCase(cfg, xid, xid);
    end

    printSummary(results, xapps);
end

function out = runCase(cfg, xappId, name)

    fprintf("\n=== xApp Single Case: %s ===\n", name);

    scenario = ScenarioBuilder(cfg);
    kernel   = RanKernelNR(cfg, scenario);

    if isempty(xappId)
        ric = NearRTRIC(cfg, "xappSet", []);
    else
        ric = NearRTRIC(cfg, "xappSet", [string(xappId)]);
    end

    for s = 1:cfg.sim.slotPerEpisode
        state = kernel.ctx.state;
        [ric, action, ~] = ric.step(state);
        kernel = kernel.step(action);
    end

    out = summarizeKpi(kernel.ctx.tmp.kpi);
end

function out = summarizeKpi(kpi)

    out = struct();
    out.throughput_Mbps = kpi.capacity.throughput_Mbps_total;
    out.fairness = kpi.capacity.jainFairness;
    out.top10Share = kpi.capacity.top10Share;
    out.dropRatio = kpi.reliability.dropRatio;
    out.meanBLER = kpi.reliability.meanBLER;
    out.meanSINR = kpi.phy.meanSINR_dB;
    out.meanInterf = kpi.resource.meanInterference_dBm;
    out.prbUtilMean = kpi.resource.prbUtilMean;
    out.congestionIndex = kpi.system.congestionIndex;
    out.bitPerJ = kpi.efficiency.bitPerJ;
    out.energy_J_total = kpi.efficiency.energy_J_total;
end

function printSummary(results, xapps)

    fprintf("\n===== xApp Single KPI Summary =====\n");
    header = [ ...
        'Case                     Thr(Mbps)  Fairness  Top10Share  DropRatio  ' ...
        'BLER     MeanSINR  Interf(dBm)  PRButil  CongIdx  Bit/J     Energy(J)\n'];
    fprintf('%s', header);

    printLine("baseline", results.baseline);

    for i = 1:numel(xapps)
        name = xapps(i);
        printLine(char(name), results.(name));
    end
end

function printLine(name, r)

    fprintf("%-24s %9.2f  %8.3f  %9.3f  %8.4f  %7.4f  %8.2f  %10.2f  %7.3f  %7.3f  %8.1f  %9.1f\n", ...
        name, r.throughput_Mbps, r.fairness, r.top10Share, r.dropRatio, r.meanBLER, ...
        r.meanSINR, r.meanInterf, r.prbUtilMean, r.congestionIndex, r.bitPerJ, r.energy_J_total);
end
