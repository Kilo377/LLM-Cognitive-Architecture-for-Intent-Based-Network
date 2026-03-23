function run_xapp_fairness_no_thr_loss_debug()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    rootDir = setup_path();

    cfg = default_config();
    cfg.debug.enable = false;
    cfg.debug.enableXApp = true;
    cfg.sim.slotPerEpisode = 2000;
    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    xset = ["xapp_fairness_no_thr_loss"];

    fprintf("\n=== xApp Debug Case: fairness_no_thr_loss ===\n");

    scenario = ScenarioBuilder(cfg);
    kernel   = RanKernelNR(cfg, scenario);
    ric      = NearRTRIC(cfg, "xappSet", xset);

    for s = 1:cfg.sim.slotPerEpisode
        state = kernel.ctx.state;
        [ric, action, ~] = ric.step(state);
        kernel = kernel.step(action);

        if mod(s, 200) == 0
            fprintf('[progress][fairness_no_thr_loss] slot=%d/%d\n', s, cfg.sim.slotPerEpisode);
        end
    end

    r = summarizeKpi(kernel.ctx.tmp.kpi);
    fprintf("\n===== fairness_no_thr_loss KPI Summary =====\n");
    fprintf("Thr(Mbps): %.2f  Fairness: %.3f  Top10: %.3f  DropRatio: %.4f  BLER: %.4f\n", ...
        r.throughput_Mbps, r.fairness, r.top10Share, r.dropRatio, r.meanBLER);
end

function out = summarizeKpi(kpi)

    out = struct();
    out.throughput_Mbps = kpi.capacity.throughput_Mbps_total;
    out.fairness = kpi.capacity.jainFairness;
    out.top10Share = kpi.capacity.top10Share;
    out.dropRatio = kpi.reliability.dropRatio;
    out.meanBLER = kpi.reliability.meanBLER;
end
