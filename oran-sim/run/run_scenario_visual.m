function result = run_scenario_visual()
%RUN_MVP_RIC_VISUAL Quantitative experiment with realtime visualization

    %% =========================================================
    % Setup path
    %% =========================================================
    rootDir = setup_path();

    fprintf('\n============================\n');
    fprintf('[RUN] Quantitative RIC experiment (Visual Mode)\n');
    fprintf('============================\n');

    %% =========================================================
    % Config
    %% =========================================================
    cfg = default_config();

    if ~isfield(cfg,'nearRT'); cfg.nearRT = struct(); end
    if ~isfield(cfg.nearRT,'periodSlot')
        cfg.nearRT.periodSlot = 10;
    end

    cfg.nearRT.xappRoot = fullfile(rootDir,"xapps");

    totalSlot = 5000;
    cfg.sim.slotPerEpisode = totalSlot;

    %% =========================================================
    % Select xApps
    %% =========================================================
    xAppSet = [
        %"xapp_trajectory_handover"
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
    ric = NearRTRIC(cfg, "xappSet", xAppSet);

    %% =========================================================
    % Visualization
    %% =========================================================
    viz = VisualizationManager();

    trajHistory = cell(cfg.scenario.numUE,1);
    for u = 1:cfg.scenario.numUE
        trajHistory{u} = [];
    end

    %% =========================================================
    % Main loop
    %% =========================================================
    lastAction = RanActionBus.init(cfg);

    for slot = 1:totalSlot

        % --- RIC step ---
        [ric, action] = ric.step(ran.getState());
        lastAction = action;

        % --- RAN step ---
        ran = ran.stepWithAction(lastAction);

        % --- 取当前状态 ---
        state = ran.getState();

        % --- 记录轨迹 ---
        for u = 1:cfg.scenario.numUE
            trajHistory{u}(end+1,:) = state.ue.pos(u,:);
        end

        % --- 扩展字段 ---
        state.ext.trajHistory = trajHistory;
        state.ext.handoverCount = state.kpi.handoverCount;

        % --- 更新可视化 ---
        viz.update(state);
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
    % Return result
    %% =========================================================
    result = struct();
    result.xAppSet = xAppSet;
    result.simDuration_s = totalTime;
    result.avgThroughput_Mbps = avgThroughput_Mbps;
    result.handover_count = report.handover_count;
    result.dropped_total = report.dropped_total;
    result.dropped_urllc = report.dropped_urllc;
end
