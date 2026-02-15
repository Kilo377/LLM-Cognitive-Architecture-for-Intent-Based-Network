function result = run_mvp_ric()
%RUN_MVP_RIC Quantitative experiment runner
%
% - Fixed slot experiment
% - GitHub safe path handling
% - Absolute xApp root
% - Structured KPI output

    %% =========================================================
    % Setup project path (robust, GitHub-safe)
    %% =========================================================
    rootDir = setup_path();

    fprintf('\n============================\n');
    fprintf('[RUN] Quantitative RIC experiment\n');
    fprintf('============================\n');

    %% =========================================================
    % Config
    %% =========================================================
    cfg = default_config();

    if ~isfield(cfg,'nearRT'); cfg.nearRT = struct(); end
    if ~isfield(cfg.nearRT,'periodSlot')
        cfg.nearRT.periodSlot = 10;
    end

    % IMPORTANT: absolute xApp root
    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    %% =========================================================
    % Fixed slot count experiment
    %% =========================================================
    totalSlot = 2 * 5000; %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%time
    cfg.sim.slotPerEpisode = totalSlot;

    %% =========================================================
    % Select xApps (edit here)
    %% =========================================================
    xAppSet = [
         %"xapp_fair_scheduler"
         %"xapp_trajectory_handover"
         "xapp_throughput_scheduler"
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
    ran = RanKernelNR(cfg, scenario);

    %% =========================================================
    % RIC
    %% =========================================================
    ric = NearRTRIC(cfg, "xappSet", xAppSet);

    %% =========================================================
    % Main loop
    %% =========================================================
    lastAction = RanActionBus.init(cfg);

    for slot = 1:totalSlot
        [ric, action] = ric.step(ran.getState());

        lastAction = action;
        ran = ran.stepWithAction(lastAction);
    end

    %% =========================================================
    % Final KPI
    %% =========================================================
    report = ran.finalize();

    totalTime = totalSlot * cfg.sim.slotDuration;
    avgThroughput_Mbps = report.throughput_bps_total / totalTime / 1e6;

    fprintf('\n===== FINAL KPI REPORT =====\n');
    fprintf('Sim duration: %.2f s\n', totalTime);
    fprintf('Avg Throughput: %.2f Mbps\n', avgThroughput_Mbps);
    fprintf('HO count: %d\n', report.handover_count);
    fprintf('Dropped total: %d\n', report.dropped_total);
    fprintf('Dropped URLLC: %d\n', report.dropped_urllc);
    fprintf('============================\n\n');

    %% =========================================================
    % Return structured result
    %% =========================================================
    result = struct();
    result.xAppSet = xAppSet;
    result.simDuration_s = totalTime;
    result.avgThroughput_Mbps = avgThroughput_Mbps;
    result.handover_count = report.handover_count;
    result.dropped_total = report.dropped_total;
    result.dropped_urllc = report.dropped_urllc;
end
