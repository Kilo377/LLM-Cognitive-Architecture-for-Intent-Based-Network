    function run_network_debug_controls()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    setup_path();

    cfg = default_config();
    cfg = applyHighLoad(cfg);
    cfg.sim.slotPerEpisode = 1000;
    cfg.debug.enable = true;
    cfg.debug.every = 200;
    cfg.debug.modules = ["selectedUEPolicy","scheduler","traffic","radio"];
    cfg.debug.level = 3;
    cfg.ctrl.selectedUEPolicy = "queueMax";

    scenario = ScenarioBuilder(cfg);
    kernel   = RanKernelNR(cfg, scenario);

    action = RanActionBus.init(cfg);
    action.debug.enableVerbose = false;

    action.radio.interferenceCouplingFactor = 5.0;
    action.handover.hysteresisOffset_dB = 10 * ones(cfg.scenario.numCell,1);
    action.handover.tttOffset_slot = -10 * ones(cfg.scenario.numCell,1);
    action.rlf.sinrThresholdOffset_dB = 30;
    action.qos.servicePriority = struct('eMBB',1.0,'URLLC',2.0,'mMTC',1.0);

    for s = 1:cfg.sim.slotPerEpisode
        kernel = kernel.step(action);
    end
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
