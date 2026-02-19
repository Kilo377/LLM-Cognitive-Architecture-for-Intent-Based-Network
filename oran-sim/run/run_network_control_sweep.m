function resultTable = run_network_control_sweep()

    clc;
    format long g     % 关闭 1.0e+03 * 缩放显示
    format compact

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
        "sched_boostMulti"
    };

    fprintf('\n=========== Network Control Sweep ===========\n');
    fprintf(['%-18s %-12s %-12s %-10s %-8s %-8s %-8s %-8s %-8s %-8s\n'], ...
        'Exp','Thr(Mbps)','Energy(J)','SINR','MCS','BLER','DropR','HO','RLF','PRButil');

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
        disp("UE per cell distribution:");
    for c=1:cfg.scenario.numCell
        disp([ "Cell ", num2str(c), " UE count: ", ...
            num2str(sum(state.ue.servingCell==c)) ]);
    end
        report = ran.finalize();
        kpi    = state.kpi;

        % ---- derive drop ratio ----
        totalBits = sum(kpi.throughputBitPerUE);
        totalPkt  = totalBits + kpi.dropTotal;
        dropRatio = kpi.dropTotal / max(totalPkt,1);

        % ---- PRB utilization mean ----
        prbUtilMean = mean(kpi.prbUtilPerCell);

        %==============================
        % Print (强制普通浮点格式)
        %==============================
        fprintf(['%-18s %-12.4f %-12.2f %-10.4f %-8.2f %-8.5f %-8.5f %-8d %-8d %-8.4f\n'], ...
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
    numUE   = cfg.scenario.numUE;

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

        case "sched_boostMulti"

            % Boost UE: 1,5,10,15,20
            boostList = [1 5 10 15 20];
            boostList = boostList(boostList <= numUE);

            % 映射到 cell 1
            sel = zeros(numCell,1);
            sel(1) = boostList(1);

            action.scheduling.selectedUE = sel;

        otherwise
            % baseline
    end
end
