function run_energy_experiment()

    clc;
    fprintf("\n==============================\n");
    fprintf("Energy Control Detailed Test\n");
    fprintf("==============================\n\n");

    rootDir = setup_path();
    cfg = default_config();

    cfg.nearRT = struct();
    cfg.nearRT.periodSlot = 10;
    cfg.nearRT.xappRoot = fullfile(rootDir,"xapps");

    totalSlot = cfg.sim.slotPerEpisode;

    run_case(cfg, totalSlot, "baseline");
    run_case(cfg, totalSlot, "scale_0.8");
    run_case(cfg, totalSlot, "scale_1.1");
end

function run_case(cfg, totalSlot, caseName)

    fprintf("\n=== %s ===\n", caseName);

    scenario = ScenarioBuilder(cfg);
    ran      = RanKernelNR(cfg, scenario);

    % ---------------------------
    % Build action (energy control)
    % ---------------------------
    numCell = cfg.scenario.numCell;
    action  = struct();

    switch caseName
        case "scale_0.8"
            action.energy.basePowerScale = 0.8 * ones(numCell,1);

        case "scale_1.1"
            action.energy.basePowerScale = 1.1 * ones(numCell,1);

        otherwise
            % baseline -> empty action
    end


    % ---------------------------
    % Run
    % ---------------------------
    tick = 200;

    for slot = 1:totalSlot
        ran = ran.step(action);

        if mod(slot,tick)==0
            st = ran.getState();
            k  = st.kpi;

            thr = sum(k.throughputBitPerUE) / max(slot*cfg.sim.slotDuration,1e-12) / 1e6;
            eJ  = sum(k.energyJPerCell);

            fprintf("Slot %4d | SINR %.2f dB | Thr %.1f Mbps | Energy %.0f J\n", ...
                slot, k.meanSINR_dB, thr, eJ);
        end
    end

    rep = ran.finalize();
    st  = ran.getState();
    k   = st.kpi;

    fprintf("\nFINAL:\n");
    fprintf("Throughput : %.2f Mbps\n", rep.throughput_bps_total/1e6);
    fprintf("Energy     : %.2f J\n", rep.energy_J_total);
    fprintf("Mean SINR  : %.2f dB\n", k.meanSINR_dB);
    fprintf("HO         : %d\n", k.handoverCount);
    fprintf("RLF        : %d\n", k.rlfCount);
    fprintf("----------------------------------------\n");
end
