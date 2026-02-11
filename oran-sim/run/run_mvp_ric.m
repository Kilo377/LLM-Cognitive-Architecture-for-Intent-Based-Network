function run_mvp_ric()
%RUN_MVP_RIC MVP: non-RT policy selects xApp, near-RT runs xApp, RAN executes action

    %% path
    thisFile = mfilename('fullpath');
    runDir   = fileparts(thisFile);
    rootDir  = fileparts(runDir);
    addpath(genpath(rootDir));

    fprintf('[RUN] MVP RIC start\n');

    %% cfg
    cfg = default_config();

    % near-RT tick interval (slot)
    if ~isfield(cfg,'nearRT'); cfg.nearRT = struct(); end
    if ~isfield(cfg.nearRT,'periodSlot'); cfg.nearRT.periodSlot = 10; end

    %% scenario + kernel
    scenario = ScenarioBuilder(cfg);
    ran = RanKernelNR(cfg, scenario);

    %% near-RT RIC
    ric = NearRTRIC(cfg);

    %% non-RT trigger (MVP): fixed rApp policy
    policy = struct();
    policy.selectedXApp = "xapp_mac_scheduler_urllc_mvp";
    ric = ric.setPolicy(policy);

    %% visualization
    viz = VisualizationManager();

    %% loop
    totalSlot = cfg.sim.slotPerEpisode;

    lastAction = RanActionBus.init(cfg);

    for slot = 1:totalSlot

        % near-RT step: only updates action on ticks, otherwise returns cached action
        [ric, action, info] = ric.step(ran.getState()); %#ok<ASGLU>
        lastAction = action;

        % RAN executes action each slot
        ran = ran.stepWithAction(lastAction);

        % visualize
        viz.update(ran.getState());

        % print every 1s
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
                t, thr/1e6, s.kpi.handoverCount, s.kpi.dropURLLC);
        end

        if ~ishandle(viz.fig)
            fprintf('[RUN] window closed, stop\n');
            break;
        end
        pause(0.01);
    end

    report = ran.finalize();
    fprintf('\n===== MVP RIC REPORT =====\n');
    fprintf('Total throughput: %.2f Mbps\n', report.throughput_bps_total/1e6);
    fprintf('HO count: %d\n', report.handover_count);
    fprintf('Dropped packets: total=%d, URLLC=%d\n', report.dropped_total, report.dropped_urllc);
    fprintf('[RUN] MVP RIC finished\n');
end
