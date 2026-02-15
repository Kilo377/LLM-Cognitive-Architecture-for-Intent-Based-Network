function result = run_ric()
%RUN_RIC Modern modular ORAN-SIM runner
%
% - Modular Kernel compatible
% - Supports RIC + xApps
% - Stable path handling
% - Clean KPI output

    %% =========================================================
    % Setup path
    %% =========================================================
    rootDir = setup_path();

    fprintf('\n============================\n');
    fprintf('[RUN] Modular ORAN-SIM experiment\n');
    fprintf('============================\n');

    %% =========================================================
    % Config
    %% =========================================================
    cfg = default_config();

    if ~isfield(cfg,'nearRT')
        cfg.nearRT = struct();
    end

    if ~isfield(cfg.nearRT,'periodSlot')
        cfg.nearRT.periodSlot = 10;
    end

    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    %% =========================================================
    % Simulation length
    %% =========================================================
    totalSlot = 0.5 * 10000;
    cfg.sim.slotPerEpisode = totalSlot;

    %% =========================================================
    % Select xApps
    %% =========================================================
    xAppSet = [
       % "xapp_fair_scheduler"
    ];

    if isempty(xAppSet)
        fprintf('[RUN] Mode: BASELINE\n');
    else
        fprintf('[RUN] Enabled xApps:\n');
        disp(xAppSet);
    end

    %% =========================================================
    % Scenario + Kernel
    %% =========================================================
    scenario = ScenarioBuilder(cfg);
    ran      = RanKernelNR(cfg, scenario);

    %% =========================================================
    % RIC
    %% =========================================================
    ric = NearRTRIC(cfg, "xappSet", xAppSet);

    %% =========================================================
    % Main Loop
    %% =========================================================
    action = RanActionBus.init(cfg);

    for slot = 1:totalSlot

        % RIC update
        [ric, action] = ric.step(ran.getState());

        % Kernel step (NEW unified interface)
        ran = ran.step(action);

    end

    %% =========================================================
    % Finalize
    %% =========================================================
    report = ran.finalize();

    simTime = totalSlot * cfg.sim.slotDuration;

    fprintf('\n===== FINAL KPI REPORT =====\n');
    fprintf('Sim duration: %.2f s\n', simTime);
    fprintf('Total throughput: %.2f Mbps\n', report.throughput_bps_total/1e6);
    fprintf('HO count: %d\n', report.handover_count);
    fprintf('Dropped total: %d\n', report.drop_total);
    fprintf('Dropped URLLC: %d\n', report.drop_urllc);

    fprintf('Energy total: %.2f J\n', report.energy_J_total);
    fprintf('Energy efficiency: %.2f bit/J\n', report.energy_eff_bit_per_J);
    fprintf('============================\n\n');

    %% =========================================================
    % Structured result
    %% =========================================================
    result = struct();
    result.simDuration_s = simTime;
    result.xAppSet       = xAppSet;
    result.throughput_Mbps = report.throughput_bps_total/1e6;
    result.handover_count  = report.handover_count;
    result.drop_total      = report.drop_total;
    result.drop_urllc      = report.drop_urllc;
    result.energy_J        = report.energy_J_total;
    result.energy_eff      = report.energy_eff_bit_per_J;
end
