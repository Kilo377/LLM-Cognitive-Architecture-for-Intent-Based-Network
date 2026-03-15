function run_network_load_pressure_compare()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    setup_path();

    cfgBase = default_config();
    cfgBase.debug.enable = false;
    cfgBase.sim.slotPerEpisode = 250;

    cfgHigh = applyHighLoad(cfgBase);

    cases = {
        "baseline", cfgBase;
        "high_load", cfgHigh
    };

    results = struct();

    for ci = 1:size(cases,1)
        name = cases{ci,1};
        cfg  = cases{ci,2};

        fprintf("\n=== Pressure Chain Case: %s ===\n", name);

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);

        for s = 1:cfg.sim.slotPerEpisode
            kernel = kernel.step([]);
        end

        results.(name) = summarizeKpi(kernel.ctx.tmp.kpi);
    end

    printSummary(results);
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
    out.prbUtilMean = kpi.resource.prbUtilMean;
    out.congestionIndex = kpi.system.congestionIndex;
    out.energy_J_total = kpi.efficiency.energy_J_total;
    out.meanSINR_dB = kpi.phy.meanSINR_dB;
end

function printSummary(results)

    names = fieldnames(results);

    fprintf("\n===== Network Load Pressure KPI Summary =====\n");
    fprintf("Case                Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  Energy(J)\n");

    for i = 1:numel(names)
        r = results.(names{i});
        fprintf("%-18s %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %9.1f\n", ...
            names{i}, r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.energy_J_total);
    end
end
