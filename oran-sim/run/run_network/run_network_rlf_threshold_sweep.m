function run_network_rlf_threshold_sweep()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    setup_path();

    cfg = default_config();
    cfg = applyHighLoad(cfg);
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 1000;

    % Weak-link fixed conditions
    fixedInterf = 9.0;
    fixedTxOff_dB = -18;

    rlfList = [-10 0 10 20 30];

    results = struct();

    for i = 1:numel(rlfList)
        v = rlfList(i);

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);

        action = RanActionBus.init(cfg);
        action.radio.interferenceCouplingFactor = fixedInterf;
        action.radio.txPowerOffset_dB = fixedTxOff_dB * ones(cfg.scenario.numCell,1);
        action.rlf.sinrThresholdOffset_dB = v;

        for s = 1:cfg.sim.slotPerEpisode
            kernel = kernel.step(action);
        end

        results(i).value = v;
        results(i).kpi = summarizeKpi(kernel.ctx.tmp.kpi);
    end

    printSummary(results, rlfList, fixedInterf, fixedTxOff_dB, cfg.sim.slotPerEpisode);
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

function k = summarizeKpi(kpi)

    k = struct();
    k.throughput_Mbps = kpi.capacity.throughput_Mbps_total;
    k.dropRatio = kpi.reliability.dropRatio;
    k.meanBLER = kpi.reliability.meanBLER;
    k.prbUtilMean = kpi.resource.prbUtilMean;
    k.congestionIndex = kpi.system.congestionIndex;
    k.meanSINR_dB = kpi.phy.meanSINR_dB;
    k.energy_J_total = kpi.efficiency.energy_J_total;
    k.bitPerJ = kpi.efficiency.bitPerJ;
    if isfield(kpi,'stability') && isfield(kpi.stability,'handoverCount')
        k.handoverCount = kpi.stability.handoverCount;
    else
        k.handoverCount = 0;
    end
    if isfield(kpi,'reliability') && isfield(kpi.reliability,'rlfCount')
        k.rlfCount = kpi.reliability.rlfCount;
    else
        k.rlfCount = 0;
    end
end

function printSummary(results, rlfList, fixedInterf, fixedTxOff_dB, slotCount)

    fprintf("\n===== RLF/SINR Stress Test =====\n");
    fprintf("Fixed: interferenceCouplingFactor=%.2f | txPowerOffset_dB=%.1f | slots=%d\n", ...
        fixedInterf, fixedTxOff_dB, slotCount);

    fprintf("\n===== Network RLF Threshold Sweep =====\n");
    fprintf("Value   Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  RLFcnt  Energy(J)\n");
    for i = 1:numel(rlfList)
        r = results(i).kpi;
        fprintf("%5.1f  %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %6.0f  %9.1f\n", ...
            rlfList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.rlfCount, r.energy_J_total);
    end
end
