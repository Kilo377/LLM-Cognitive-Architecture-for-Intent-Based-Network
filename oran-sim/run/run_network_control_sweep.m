function resultTable = run_network_control_sweep()

    clc;

    rootDir = setup_path();
    cfgBase = default_config();

    cfgBase.nearRT = struct();
    cfgBase.nearRT.periodSlot = 10;
    cfgBase.nearRT.xappRoot = fullfile(rootDir,"xapps");

    totalSlot = cfgBase.sim.slotPerEpisode;

    %==============================
    % Define experiments
    %==============================
    experiments = {
        "baseline"
        "power_-5dB"
        "power_+5dB"
        "sleep_light"
        "sleep_deep"
        "bw_0.5"
        "bw_0.8"
        "energy_0.8"
        "energy_1.1"
        "sched_boostUE1"
    };

    fprintf('\n=========== Network Control Sweep ===========\n');
    fprintf(['%-15s %-10s %-8s %-8s %-8s %-8s %-8s %-8s %-8s %-8s\n'], ...
        'Exp','Thr(M)','Energy','SINR','MCS','BLER','DropR','HO','RLF','PRButil');

    resultTable = [];

    %==============================
    % Loop experiments
    %==============================
    for e = 1:length(experiments)

        expName = experiments{e};
        fprintf('\nRunning: %s\n', expName);

        cfg = cfgBase;

        scenario = ScenarioBuilder(cfg);
        ran      = RanKernelNR(cfg, scenario);

        action = build_action(expName, cfg);

        %==============================
        % Run episode
        %==============================
        for slot = 1:totalSlot
            ran = ran.step(action);
        end

        %==============================
        % Get final state + KPI
        %==============================
        state  = ran.getState();
        report = ran.finalize();

        kpi = state.kpi;

        % ---- derive drop ratio ----
        totalBits = sum(kpi.throughputBitPerUE);
        totalPkt  = totalBits + kpi.dropTotal;
        dropRatio = kpi.dropTotal / max(totalPkt,1);

        % ---- PRB utilization mean ----
        prbUtilMean = mean(kpi.prbUtilPerCell);

        %==============================
        % Print
        %==============================
        fprintf(['%-15s %-10.2f %-8.2f %-8.2f %-8.2f %-8.4f %-8.4f %-8d %-8d %-8.2f\n'], ...
            expName, ...
            report.throughput_bps_total/1e6, ...
            report.energy_J_total, ...
            kpi.meanSINR_dB, ...
            kpi.meanMCS, ...
            kpi.meanBLER, ...
            dropRatio, ...
            kpi.handoverCount, ...
            kpi.rlfCount, ...
            prbUtilMean);

        %==============================
        % Store table
        %==============================
        resultTable = [resultTable;
            report.throughput_bps_total/1e6,...
            report.energy_J_total,...
            kpi.meanSINR_dB,...
            kpi.meanMCS,...
            kpi.meanBLER,...
            dropRatio,...
            kpi.handoverCount,...
            kpi.rlfCount,...
            prbUtilMean];
    end

    fprintf('\n=============================================\n\n');
end

function action = build_action(expName, cfg)

    numCell = cfg.scenario.numCell;

    action = struct();

    switch expName

        case "power_-5dB"
            action.power.cellTxPowerOffset_dB = -5 * ones(numCell,1);

        case "power_+5dB"
            action.power.cellTxPowerOffset_dB = 5 * ones(numCell,1);

        case "sleep_light"
            action.sleep.cellSleepState = ones(numCell,1);

        case "sleep_deep"
            action.sleep.cellSleepState = 2 * ones(numCell,1);

        case "bw_0.5"
            action.radio.bandwidthScale = 0.5 * ones(numCell,1);

        case "bw_0.8"
            action.radio.bandwidthScale = 0.8 * ones(numCell,1);

        case "energy_0.8"
            action.energy.basePowerScale = 0.8 * ones(numCell,1);

        case "energy_1.1"
            action.energy.basePowerScale = 1.1 * ones(numCell,1);

        case "sched_boostUE1"
            action.scheduling.selectedUE = ones(numCell,1);

        otherwise
            % baseline
    end
end
