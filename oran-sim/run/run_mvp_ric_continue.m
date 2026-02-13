function run_mvp_ric_continue()
%RUN_MVP_RIC
% Experiment-level controller for near-RT RIC
%
% Responsibilities:
% - Build config
% - Select xApp set (experiment control)
% - Create RIC
% - Run simulation loop
%
% You only need to edit the xAppSet section below.

    %% =========================================================
    % Path setup
    %% =========================================================
    thisFile = mfilename('fullpath');
    runDir   = fileparts(thisFile);
    rootDir  = fileparts(runDir);
    addpath(genpath(rootDir));

    fprintf('[RUN] MVP RIC start\n');

    %% =========================================================
    % Config
    %% =========================================================
    cfg = default_config();

    if ~isfield(cfg,'nearRT'); cfg.nearRT = struct(); end
    if ~isfield(cfg.nearRT,'periodSlot')
        cfg.nearRT.periodSlot = 10;
    end

    %% =========================================================
    % ======== 选择本次实验启用的 xApp 集合（只改这里） ========
    %% =========================================================

    xAppSet = [
        % "xapp_mac_scheduler_urllc_mvp"
        % "xapp_trajectory_handover"
        % "xapp_throughput_scheduler"
    ];

    % 如果只想跑单个：
    % xAppSet = "xapp_mac_scheduler_urllc_mvp";

    fprintf('[RUN] Enabled xApps:\n');
    disp(xAppSet);

    %% =========================================================
    % Scenario + Kernel
    %% =========================================================
    scenario = ScenarioBuilder(cfg);
    ran = RanKernelNR(cfg, scenario);

    %% =========================================================
    % near-RT RIC (直接带 xAppSet 初始化)
    %% =========================================================
    ric = NearRTRIC(cfg, "xappSet", xAppSet);

    %% =========================================================
    % Visualization
    %% =========================================================
    viz = VisualizationManager();

    %% =========================================================
    % Simulation loop
    %% =========================================================
    totalSlot = cfg.sim.slotPerEpisode;
    lastAction = RanActionBus.init(cfg);

    for slot = 1:totalSlot

        % near-RT step
        [ric, action, info] = ric.step(ran.getState()); 
        lastAction = action;

        % RAN executes action
        ran = ran.stepWithAction(lastAction);

        % visualization
        viz.update(ran.getState());

        %% ---- periodic print ----
        if isfield(cfg,'nonRT') && isfield(cfg.nonRT,'periodSlot')
            printEvery = cfg.nonRT.periodSlot;
        else
            printEvery = round(1 / cfg.sim.slotDuration);
        end

        if mod(slot, printEvery) == 0
            s = ran.getState();
            t = s.time.t_s;
            thr = sum(s.kpi.throughputBitPerUE) / max(t,1e-9);

            fprintf('[t=%.2fs] thr=%.2f Mbps, HO=%d, URLLCdrop=%d\n', ...
                t, thr/1e6, ...
                s.kpi.handoverCount, ...
                s.kpi.dropURLLC);

            % 打印当前 tick 使用的 xApp
            if isfield(info,'xAppSources')
                fprintf('  Active xApps: ');
                disp(info.xAppSources);
            end
        end

        if ~ishandle(viz.fig)
            fprintf('[RUN] window closed, stop\n');
            break;
        end

        pause(0.01);
    end

    %% =========================================================
    % Final report
    %% =========================================================
    report = ran.finalize();

    fprintf('\n===== MVP RIC REPORT =====\n');
    fprintf('Enabled xApps: \n');
    disp(xAppSet);

    fprintf('Total throughput: %.2f Mbps\n', ...
        report.throughput_bps_total/1e6);

    fprintf('HO count: %d\n', report.handover_count);

    fprintf('Dropped packets: total=%d, URLLC=%d\n', ...
        report.dropped_total, report.dropped_urllc);

    fprintf('[RUN] MVP RIC finished\n');
end
