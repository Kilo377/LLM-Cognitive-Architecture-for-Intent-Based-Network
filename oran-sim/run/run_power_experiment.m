function run_power_experiment()

    clc;

    rootDir = setup_path();
    cfg     = default_config();

    totalSlot = cfg.sim.slotPerEpisode;

    fprintf('\n==============================\n');
    fprintf('Power Control Detailed Test\n');
    fprintf('==============================\n\n');

    run_case(cfg, totalSlot, "baseline");
    run_case(cfg, totalSlot, "all_plus5");
    run_case(cfg, totalSlot, "cell1_plus5");
    run_case(cfg, totalSlot, "cell1_minus5");

end


% ==========================================================
function run_case(cfg, totalSlot, mode)

    fprintf('\n=== %s ===\n', mode);

    scenario = ScenarioBuilder(cfg);
    ran      = RanKernelNR(cfg, scenario);

    numCell = cfg.scenario.numCell;

    action = struct();

    switch mode
        case "baseline"

        case "all_plus5"
            action.power.cellTxPowerOffset_dB = 5 * ones(numCell,1);

        case "cell1_plus5"
            v = zeros(numCell,1);
            v(1) = 5;
            action.power.cellTxPowerOffset_dB = v;

        case "cell1_minus5"
            v = zeros(numCell,1);
            v(1) = -5;
            action.power.cellTxPowerOffset_dB = v;
    end

    % ===============================
    % Run
    % ===============================
    for slot = 1:totalSlot

        ran = ran.step(action);

        if mod(slot,200)==0
            state = ran.getState();

            fprintf('Slot %4d | SINR %.2f dB | Thr %.1f Mbps | Energy %.0f J\n',...
                slot,...
                state.kpi.meanSINR_dB,...
                sum(state.kpi.throughputBitPerUE)/1e6,...
                sum(state.kpi.energyJPerCell));
        end
    end

    % ===============================
    % Final summary
    % ===============================
    state  = ran.getState();
    report = ran.finalize();

    fprintf('\nFINAL:\n');
    fprintf('Throughput : %.2f Mbps\n', report.throughput_bps_total/1e6);
    fprintf('Energy     : %.2f J\n', report.energy_J_total);
    fprintf('Mean SINR  : %.2f dB\n', state.kpi.meanSINR_dB);
    fprintf('HO         : %d\n', state.kpi.handoverCount);
    fprintf('RLF        : %d\n', state.kpi.rlfCount);

    % Serving cell distribution
    serving = state.ue.servingCell;
    for c = 1:numCell
        fprintf('UE in Cell %d: %d\n', c, sum(serving==c));
    end

    fprintf('----------------------------------------\n');

end
