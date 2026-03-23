function run_network_weightue_sensitivity()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    setup_path();

    cfg = default_config();
    cfg = applyHighLoad(cfg);
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 2000;

    randAmpList = [0.0 0.2 0.5 1.0];
    results = struct();

    for i = 1:numel(randAmpList)
        v = randAmpList(i);

        cfgCase = cfg;
        if ~isfield(cfgCase,'ctrl')
            cfgCase.ctrl = struct();
        end
        cfgCase.ctrl.weightUE = struct('randAmp', v);

        scenario = ScenarioBuilder(cfgCase);
        kernel   = RanKernelNR(cfgCase, scenario);

        weightMean = zeros(cfgCase.sim.slotPerEpisode,1);
        weightStd  = zeros(cfgCase.sim.slotPerEpisode,1);

        for s = 1:cfgCase.sim.slotPerEpisode
            kernel = kernel.step([]);
            if isprop(kernel.ctx,'ctrl') && isfield(kernel.ctx.ctrl,'weightUE')
                w = double(kernel.ctx.ctrl.weightUE(:));
                if ~isempty(w)
                    weightMean(s) = mean(w);
                    weightStd(s) = std(w);
                end
            end
        end

        out = summarizeKpi(kernel.ctx.tmp.kpi);
        out.weightMean = mean(weightMean);
        out.weightStd = mean(weightStd);
        results(i).value = v;
        results(i).kpi = out;
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
    out.jainFairness = kpi.capacity.jainFairness;
    out.top10Share = kpi.capacity.top10Share;
    out.dropRatio = kpi.reliability.dropRatio;
    out.meanBLER = kpi.reliability.meanBLER;
    out.prbUtilMean = kpi.resource.prbUtilMean;
    out.congestionIndex = kpi.system.congestionIndex;
    out.energy_J_total = kpi.efficiency.energy_J_total;
    out.meanSINR_dB = kpi.phy.meanSINR_dB;
end

function printSummary(results)

    fprintf("\n===== weightUE randAmp Sensitivity =====\n");
    fprintf("randAmp  Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  Jain   Top10  Energy(J)  wMean  wStd\n");

    for i = 1:numel(results)
        r = results(i).kpi;
        fprintf("%7.2f  %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %5.3f  %5.3f  %9.1f  %5.2f  %4.2f\n", ...
            results(i).value, r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.jainFairness, r.top10Share, r.energy_J_total, ...
            r.weightMean, r.weightStd);
    end
end
