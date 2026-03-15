function run_xapp_capacity_energy_compare_visual()

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

    cases = {
        "baseline", [];
        "capacity_only", ["xapp_capacity_boost"];
        "energy_only", ["xapp_energy_saver"];
        "capacity_plus_energy", ["xapp_capacity_boost", "xapp_energy_saver"]
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
    out.bitPerJ = kpi.efficiency.bitPerJ;
end

function printSummary(results)

    names = fieldnames(results);

    fprintf("\n===== xApp Capacity/Energy KPI Summary =====\n");
    fprintf("Case                    Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  Bit/J    Energy(J)\n");

    for i = 1:numel(names)
        r = results.(names{i});
        fprintf("%-22s %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %7.1f  %9.1f\n", ...
            names{i}, r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.bitPerJ, r.energy_J_total);
    end
end

function plotSummary(results, caseNames)

    n = numel(caseNames);
    thr = zeros(n,1);
    drop = zeros(n,1);
    bitj = zeros(n,1);
    energy = zeros(n,1);

    for i = 1:n
        r = results.(caseNames{i});
        thr(i) = r.throughput_Mbps;
        drop(i) = r.dropRatio;
        bitj(i) = r.bitPerJ;
        energy(i) = r.energy_J_total;
    end

    figure('Name','xApp Capacity/Energy Compare');

    subplot(2,2,1);
    bar(thr);
    title('Throughput (Mbps)');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,2,2);
    bar(drop);
    title('Drop Ratio');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,2,3);
    bar(bitj);
    title('Bit/J');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,2,4);
    bar(energy);
    title('Energy (J)');
    grid on;
    set(gca,'XTickLabel',caseNames);
end
