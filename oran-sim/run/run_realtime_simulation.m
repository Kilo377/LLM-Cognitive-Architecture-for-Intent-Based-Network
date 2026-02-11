function run_realtime_simulation()
%RUN_REALTIME_SIMULATION
% Continuous real-time simulation and visualization for ORAN-SIM
%
% 特点：
% - 持续 slot 级推进
% - 实时可视化 RAN 状态
% - 不依赖 xApp / RIC
% - 可作为后续 near-RT RIC 的运行外壳

    %% ===============================
    % Path setup
    %% ===============================
    thisFile = mfilename('fullpath');
    runDir   = fileparts(thisFile);
    rootDir  = fileparts(runDir);
    addpath(genpath(rootDir));

    fprintf('[RUN] ORAN-SIM realtime simulation start\n');

    %% ===============================
    % Config & scenario
    %% ===============================
    cfg = default_config();

    scenario = ScenarioBuilder(cfg);

    %% ===============================
    % RAN kernel
    %% ===============================
    ran = RanKernelNR(cfg, scenario);

    %% ===============================
    % Visualization manager
    %% ===============================
    viz = VisualizationManager();

    %% ===============================
    % Simulation control parameters
    %% ===============================
    totalSlot   = cfg.sim.slotPerEpisode;
    pauseTime  = 0.01;      % 控制"仿真速度"，0 表示尽可能快
    printEvery = round(1 / cfg.sim.slotDuration); % 每 1 秒打印一次

    %% ===============================
    % Main loop
    %% ===============================
    for slot = 1:totalSlot

        % ---- step RAN ----
        ran = ran.stepBaseline();

        % ---- get state ----
        state = ran.getState();

        % ---- update visualization ----
        viz.update(state);

        % ---- optional console log ----
        if mod(slot, printEvery) == 0
            t = state.time.t_s;
            thr = sum(state.kpi.throughputBitPerUE) / max(t,1e-9);
            ho  = state.kpi.handoverCount;
            du  = state.kpi.dropURLLC;
            fprintf('[t=%.2fs] thr=%.2f Mbps, HO=%d, URLLCdrop=%d\n', ...
                t, thr/1e6, ho, du);
        end

        % ---- pacing ----
        if pauseTime > 0
            pause(pauseTime);
        else
            drawnow limitrate;
        end

        % ---- allow manual stop ----
        if ~ishandle(viz.fig)
            fprintf('[RUN] Visualization window closed, stop simulation\n');
            break;
        end
    end

    %% ===============================
    % Final report
    %% ===============================
    report = ran.finalize();

    fprintf('\n===== REALTIME SIMULATION REPORT =====\n');
    fprintf('Total throughput: %.2f Mbps\n', ...
        report.throughput_bps_total / 1e6);
    fprintf('HO count: %d\n', report.handover_count);
    fprintf('Dropped packets: total=%d, URLLC=%d\n', ...
        report.dropped_total, report.dropped_urllc);
    fprintf('Total energy: %.2f J\n', report.energy_J_total);
    fprintf('Energy efficiency: %.3e bit/J\n', ...
        report.energy_eff_bit_per_J);
    fprintf('PRB utilization per cell: ');
    fprintf('%.2f ', report.prb_util_perCell);
    fprintf('\n');

    fprintf('[RUN] ORAN-SIM realtime simulation finished\n');
end
