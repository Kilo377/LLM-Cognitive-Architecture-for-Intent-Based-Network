function run_network_control_sweep()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    setup_path();
    

    cfg = default_config();
    cfg = applyHighLoad(cfg);
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 250;

    results = struct();

    % -------------------------------------------------
    % 1) Tx power offset sweep
    % -------------------------------------------------
    txList = [-10 0 10];
    results.txPower = runSweep(cfg, "txPowerOffset_dB", txList);


    % -------------------------------------------------
    % 2) Bandwidth scale sweep
    % -------------------------------------------------
    bwList = [0.6 1.0 1.5];
    results.bandwidth = runSweep(cfg, "bandwidthScale", bwList);

    % -------------------------------------------------
    % 3) Sleep state sweep
    % -------------------------------------------------
    sleepList = [0 1 2];
    results.sleep = runSweep(cfg, "sleepState", sleepList);

    % -------------------------------------------------
    % 4) Energy basePowerScale sweep
    % -------------------------------------------------
    energyList = [0.6 1.0 1.4];
    results.energy = runSweep(cfg, "basePowerScale", energyList);

    % -------------------------------------------------
    % 5) Interference coupling sweep
    % -------------------------------------------------
    interfList = [0.5 1.0 2.0];
    results.interference = runSweep(cfg, "interferenceCouplingFactor", interfList);

    % -------------------------------------------------
    % 5.1) Beam control sweep (ueBeamId)
    % -------------------------------------------------
    beamList = [0 1 2 4 6 8];
    results.beam = runSweepBeam(cfg, beamList);

    % -------------------------------------------------
    % 5.2) Beam mode sweep
    % -------------------------------------------------
    beamModeList = ["static" "adaptive"];
    results.beamMode = runSweepBeamMode(cfg, beamModeList);

    % -------------------------------------------------
    % 6) Handover sweep (hysteresis)
    % -------------------------------------------------
    hoList = [-6 0 6];
    results.handoverHyst = runSweep(cfg, "handoverHysteresis", hoList);

    % -------------------------------------------------
    % 7) Handover sweep (TTT offset)
    % -------------------------------------------------
    tttList = [-10 0 10];
    results.handoverTtt = runSweep(cfg, "handoverTTT", tttList);

    % -------------------------------------------------
    % 8) Scheduling baseline vs queue-max selectedUE
    % -------------------------------------------------
    results.selectedUE = runSelectedUECases(cfg);

    printSummary(results, txList, bwList, sleepList, energyList, interfList, ...
        beamList, beamModeList, hoList, tttList);
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

function out = runSweep(cfg, sweepName, sweepVals)

    numCell = cfg.scenario.numCell;
    out = struct();

    for i = 1:numel(sweepVals)
        v = sweepVals(i);

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);

        action = RanActionBus.init(cfg);

        if sweepName == "txPowerOffset_dB"
            action.radio.txPowerOffset_dB = v * ones(numCell,1);
        elseif sweepName == "bandwidthScale"
            action.radio.bandwidthScale = v * ones(numCell,1);
        elseif sweepName == "sleepState"
            action.sleep.cellSleepState = v * ones(numCell,1);
        elseif sweepName == "basePowerScale"
            action.energy.basePowerScale = v * ones(numCell,1);
        elseif sweepName == "interferenceCouplingFactor"
            action.radio.interferenceCouplingFactor = v;
        elseif sweepName == "handoverHysteresis"
            action.handover.hysteresisOffset_dB = v * ones(numCell,1);
        elseif sweepName == "handoverTTT"
            action.handover.tttOffset_slot = v * ones(numCell,1);
        end

        for s = 1:cfg.sim.slotPerEpisode
            kernel = kernel.step(action);
        end

        out(i).value = v;
        out(i).kpi = summarizeKpi(kernel.ctx.tmp.kpi);
    end
end

function out = runSweepBeam(cfg, beamVals)

    numUE = cfg.scenario.numUE;
    out = struct();

    for i = 1:numel(beamVals)
        v = beamVals(i);

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);

        action = RanActionBus.init(cfg);

        if v > 0
            action.beam.ueBeamId = v * ones(numUE,1);
        else
            action.beam.ueBeamId = zeros(numUE,1);
        end

        for s = 1:cfg.sim.slotPerEpisode
            kernel = kernel.step(action);
        end

        out(i).value = v;
        out(i).kpi = summarizeKpi(kernel.ctx.tmp.kpi);
    end
end

function out = runSweepBeamMode(cfg, modeList)

    numUE = cfg.scenario.numUE;
    out = struct();

    for i = 1:numel(modeList)
        mode = string(modeList(i));

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);

        action = RanActionBus.init(cfg);
        action.beam.ueBeamId = zeros(numUE,1);
        action.beam.mode = mode;

        for s = 1:cfg.sim.slotPerEpisode
            kernel = kernel.step(action);
        end

        out(i).value = mode;
        out(i).kpi = summarizeKpi(kernel.ctx.tmp.kpi);
    end
end

function out = runSelectedUECases(cfg)

    cases = {"baseline", false; "queueMax", true};
    out = struct();

    for i = 1:size(cases,1)
        name = cases{i,1};
        useQueueMax = cases{i,2};

        cfgCase = cfg;
        if useQueueMax
            if ~isfield(cfgCase,'ctrl')
                cfgCase.ctrl = struct();
            end
            cfgCase.ctrl.selectedUEPolicy = "queueMax";
        end

        scenario = ScenarioBuilder(cfgCase);
        kernel   = RanKernelNR(cfgCase, scenario);

        selectedCount = 0;
        selectedValidCount = 0;
        selectedNonemptyCount = 0;

        for s = 1:cfgCase.sim.slotPerEpisode
            action = RanActionBus.init(cfgCase);
            kernel = kernel.step(action);
            [selAny, selValid, selNonempty] = evalSelectedUE(kernel.ctx, kernel.ctx.ctrl.selectedUE);
            selectedCount = selectedCount + selAny;
            selectedValidCount = selectedValidCount + selValid;
            selectedNonemptyCount = selectedNonemptyCount + selNonempty;
        end

        out.(name).kpi = summarizeKpi(kernel.ctx.tmp.kpi);
        denom = max(cfgCase.sim.slotPerEpisode * cfgCase.scenario.numCell, 1);
        out.(name).selectedRate = selectedCount / denom;
        out.(name).selectedValidRate = selectedValidCount / denom;
        out.(name).selectedNonemptyRate = selectedNonemptyCount / denom;
    end
end

function [selAny, selValid, selNonempty] = evalSelectedUE(ctx, sel)

    numCell = ctx.cfg.scenario.numCell;
    selAny = 0;
    selValid = 0;
    selNonempty = 0;

    if isempty(sel) || numel(sel) ~= numCell
        return;
    end

    for c = 1:numCell
        u = sel(c);
        if u <= 0
            continue;
        end
        selAny = selAny + 1;
        if ~isprop(ctx,'servingCell') || isempty(ctx.servingCell)
            continue;
        end
        if u > 0 && u <= numel(ctx.servingCell) && ctx.servingCell(u) == c
            selValid = selValid + 1;
            q = ctx.scenario.traffic.model.getQueue(u);
            if ~isempty(q)
                selNonempty = selNonempty + 1;
            end
        end
    end
end


function k = summarizeKpi(kpi)

    k = struct();
    k.throughput_Mbps = kpi.capacity.throughput_Mbps_total;
    if isfield(kpi.capacity,'jainFairness')
        k.jainFairness = kpi.capacity.jainFairness;
    else
        k.jainFairness = 0;
    end
    if isfield(kpi.capacity,'top10Share')
        k.top10Share = kpi.capacity.top10Share;
    else
        k.top10Share = 0;
    end
    k.dropRatio = kpi.reliability.dropRatio;
    k.meanBLER = kpi.reliability.meanBLER;
    k.prbUtilMean = kpi.resource.prbUtilMean;
    k.congestionIndex = kpi.system.congestionIndex;
    k.meanSINR_dB = kpi.phy.meanSINR_dB;
    if isfield(kpi.phy,'p10SINR_dB')
        k.p10SINR_dB = kpi.phy.p10SINR_dB;
    else
        k.p10SINR_dB = 0;
    end
    if isfield(kpi.phy,'p50SINR_dB')
        k.p50SINR_dB = kpi.phy.p50SINR_dB;
    else
        k.p50SINR_dB = 0;
    end
    if isfield(kpi.phy,'p90SINR_dB')
        k.p90SINR_dB = kpi.phy.p90SINR_dB;
    else
        k.p90SINR_dB = 0;
    end
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
    if isfield(kpi,'qos')
        k.qos = kpi.qos;
    else
        k.qos = struct();
    end
end

function printSummary(results, txList, bwList, sleepList, energyList, interfList, beamList, beamModeList, hoList, tttList)

    fprintf("\n===== KPI Link Test: txPowerOffset_dB =====\n");
    fprintf("Value   Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  Bit/J    Energy(J)\n");
    for i = 1:numel(txList)
        r = results.txPower(i).kpi;
        fprintf("%5.1f  %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %7.1f  %9.1f\n", ...
            txList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.bitPerJ, r.energy_J_total);
    end

    fprintf("\n===== KPI Link Test: bandwidthScale =====\n");
    fprintf("Value   Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  Bit/J    Energy(J)\n");
    for i = 1:numel(bwList)
        r = results.bandwidth(i).kpi;
        fprintf("%5.2f  %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %7.1f  %9.1f\n", ...
            bwList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.bitPerJ, r.energy_J_total);
    end

    fprintf("\n===== KPI Link Test: sleepState =====\n");
    fprintf("Value   Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  Bit/J    Energy(J)\n");
    for i = 1:numel(sleepList)
        r = results.sleep(i).kpi;
        fprintf("%5.0f  %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %7.1f  %9.1f\n", ...
            sleepList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.bitPerJ, r.energy_J_total);
    end

    fprintf("\n===== KPI Link Test: basePowerScale =====\n");
    fprintf("Value   Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  Bit/J    Energy(J)\n");
    for i = 1:numel(energyList)
        r = results.energy(i).kpi;
        fprintf("%5.2f  %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %7.1f  %9.1f\n", ...
            energyList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.bitPerJ, r.energy_J_total);
    end

    fprintf("\n===== KPI Link Test: interferenceCouplingFactor =====\n");
    fprintf("Value   Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  Bit/J    Energy(J)\n");
    for i = 1:numel(interfList)
        r = results.interference(i).kpi;
        fprintf("%5.2f  %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %7.1f  %9.1f\n", ...
            interfList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.bitPerJ, r.energy_J_total);
    end

    fprintf("\n===== KPI Link Test: beam ueBeamId =====\n");
    fprintf("Value   Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  p10SINR  p50SINR  p90SINR\n");
    for i = 1:numel(beamList)
        r = results.beam(i).kpi;
        fprintf("%5.0f  %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %8.2f  %8.2f  %8.2f\n", ...
            beamList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.p10SINR_dB, r.p50SINR_dB, r.p90SINR_dB);
    end

    fprintf("\n===== KPI Link Test: beam mode =====\n");
    fprintf("Mode   Thr(Mbps)  DropRatio  BLER     PRButil  CongIdx  MeanSINR  p10SINR  p50SINR  p90SINR\n");
    for i = 1:numel(beamModeList)
        r = results.beamMode(i).kpi;
        fprintf("%6s  %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %8.2f  %8.2f  %8.2f  %8.2f\n", ...
            beamModeList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.congestionIndex, r.meanSINR_dB, r.p10SINR_dB, r.p50SINR_dB, r.p90SINR_dB);
    end

    fprintf("\n===== KPI Link Test: handover hysteresisOffset_dB =====\n");
    fprintf("Value   Thr(Mbps)  DropRatio  BLER     HOcnt  RLFcnt  MeanSINR\n");
    for i = 1:numel(hoList)
        r = results.handoverHyst(i).kpi;
        fprintf("%5.1f  %9.2f  %8.4f  %7.4f  %5.0f  %6.0f  %8.2f\n", ...
            hoList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.handoverCount, r.rlfCount, r.meanSINR_dB);
    end

    fprintf("\n===== KPI Link Test: handover tttOffset_slot =====\n");
    fprintf("Value   Thr(Mbps)  DropRatio  BLER     HOcnt  RLFcnt  MeanSINR\n");
    for i = 1:numel(tttList)
        r = results.handoverTtt(i).kpi;
        fprintf("%5.1f  %9.2f  %8.4f  %7.4f  %5.0f  %6.0f  %8.2f\n", ...
            tttList(i), r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.handoverCount, r.rlfCount, r.meanSINR_dB);
    end

    fprintf("\n===== KPI Link Test: scheduling selectedUE =====\n");
    fprintf("Case                Thr(Mbps)  DropRatio  BLER     PRButil  Fairness  Top10  SelRate  SelValid  SelNonEmp\n");
    names = fieldnames(results.selectedUE);
    for i = 1:numel(names)
        r = results.selectedUE.(names{i}).kpi;
        fprintf("%-18s %9.2f  %8.4f  %7.4f  %7.3f  %7.3f  %5.3f  %7.3f  %8.3f  %8.3f\n", ...
            names{i}, r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.prbUtilMean, r.jainFairness, r.top10Share, ...
            results.selectedUE.(names{i}).selectedRate, ...
            results.selectedUE.(names{i}).selectedValidRate, ...
            results.selectedUE.(names{i}).selectedNonemptyRate);
    end

end
