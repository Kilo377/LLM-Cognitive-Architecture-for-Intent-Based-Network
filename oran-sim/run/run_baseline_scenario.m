function run_baseline_scenario()
%RUN_BASELINE_SCENARIO
% Baseline system-level NR scenario without any xApp or RIC
% Uses RanKernelNR + NrPhyMacAdapter

    %% ===============================
    % Add path
    %% ===============================
    thisFile = mfilename('fullpath');
    runDir   = fileparts(thisFile);
    rootDir  = fileparts(runDir);
    addpath(genpath(rootDir));

    fprintf('[RUN] ORAN-SIM baseline start\n');

    %% ===============================
    % Config
    %% ===============================
    cfg = default_config();

    %% ===============================
    % Build scenario
    %% ===============================
    scenario = ScenarioBuilder(cfg);

    %% ===============================
    % Init RAN kernel
    %% ===============================
    ran = RanKernelNR(cfg, scenario);

    %% ===============================
    % Main simulation loop
    %% ===============================
    for slot = 1 : cfg.sim.slotPerEpisode

        ran = ran.stepBaseline();

        % Print status every 1 second
        if mod(slot, cfg.nonRT.periodSlot) == 0

            s = ran.getState();

            % ===== KPI from state bus =====
            time_s = s.time.t_s;

            totalThroughput_bps = ...
                sum(s.kpi.throughputBitPerUE) / max(time_s, 1e-9);

            totalEnergy_J = sum(s.kpi.energyJPerCell);

            hoCount = s.kpi.handoverCount;
            dropURLLC = s.kpi.dropURLLC;

            fprintf(['[t=%.2fs] ', ...
                     'thr=%.2f Mbps, ', ...
                     'energy=%.1f J, ', ...
                     'HO=%d, ', ...
                     'URLLCdrop=%d\n'], ...
                     time_s, ...
                     totalThroughput_bps/1e6, ...
                     totalEnergy_J, ...
                     hoCount, ...
                     dropURLLC);
        end
    end

    %% ===============================
    % Final report
    %% ===============================
    report = ran.finalize();

    fprintf('\n===== BASELINE REPORT =====\n');
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

    fprintf('[RUN] ORAN-SIM baseline finished\n');
end
