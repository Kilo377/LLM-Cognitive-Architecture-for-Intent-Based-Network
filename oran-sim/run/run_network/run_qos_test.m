function run_qos_test()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    setup_path();

    cfg = default_config();
    cfg = applyHighLoad(cfg);
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 500;

    cfg.traffic.enableBurst = false;
    cfg.traffic.profileRatio = struct('eMBB',0.30,'URLLC',0.40,'mMTC',0.10,'Mixed',0.20);

    cases = {
        "baseline",   struct('eMBB',1.0,'URLLC',1.0,'mMTC',1.0);
        "urllc_high", struct('eMBB',1.0,'URLLC',5.0,'mMTC',1.0);
        "embb_high",  struct('eMBB',5.0,'URLLC',1.0,'mMTC',1.0);
        "mmtc_high",  struct('eMBB',1.0,'URLLC',1.0,'mMTC',5.0)
    };

    results = struct();

    for i = 1:size(cases,1)
        name = cases{i,1};
        sp = cases{i,2};

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);

        action = RanActionBus.init(cfg);
        action.qos.servicePriority = sp;

        for s = 1:cfg.sim.slotPerEpisode
            kernel = kernel.step(action);
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

function k = summarizeKpi(kpi)

    k = struct();
    k.throughput_Mbps = kpi.capacity.throughput_Mbps_total;
    k.dropRatio = kpi.reliability.dropRatio;
    k.meanBLER = kpi.reliability.meanBLER;
    if isfield(kpi,'reliability') && isfield(kpi.reliability,'rlfCount')
        k.rlfCount = kpi.reliability.rlfCount;
    else
        k.rlfCount = 0;
    end
    if isfield(kpi,'qos')
        k.qos = kpi.qos;
    else
        k.qos = struct();
    end
end

function printSummary(results)

    names = fieldnames(results);

    fprintf("\n===== QoS Priority Test =====\n");
    fprintf("Case        Thr(Mbps)  DropRatio  BLER     RLFcnt  URLLC_drop  eMBB_drop  mMTC_drop\n");

    for i = 1:numel(names)
        r = results.(names{i});
        q = r.qos.dropRatio;
        fprintf("%-10s %9.2f  %8.4f  %7.4f  %6.0f  %10.4f  %9.4f  %9.4f\n", ...
            names{i}, r.throughput_Mbps, r.dropRatio, r.meanBLER, r.rlfCount, ...
            q.URLLC, q.eMBB, q.mMTC);
    end

    fprintf("\n===== QoS Throughput (Mbps) =====\n");
    fprintf("Case        URLLC_thr  eMBB_thr  mMTC_thr\n");
    for i = 1:numel(names)
        r = results.(names{i});
        t = r.qos.throughput_Mbps;
        fprintf("%-10s %9.2f  %8.2f  %8.2f\n", ...
            names{i}, t.URLLC, t.eMBB, t.mMTC);
    end
end
