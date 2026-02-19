function results = run_sensitivity()

clc;

cfg0 = default_config();

rng(cfg0.sim.randomSeed);

txSweep  = cfg0.sweep.txPowerOffset_dB;
bwSweep  = cfg0.sweep.bandwidthScale;

idx = 1;
results = [];

fprintf('\n=========== Sensitivity Sweep ===========\n');

for i = 1:length(txSweep)
    for j = 1:length(bwSweep)

        cfg = cfg0;

        % Build scenario
        scenario = ScenarioBuilder(cfg);

        % Kernel
        kernel = RanKernelNR(cfg, scenario);

        % Action template
        action = RanActionBus.init(cfg);

        % Apply sweep parameters
        action.power.cellTxPowerOffset_dB = txSweep(i) * ones(cfg.scenario.numCell,1);
        action.radio.bandwidthScale       = bwSweep(j) * ones(cfg.scenario.numCell,1);

        fprintf('\nRunning: TxOffset=%d dB, BWscale=%.2f\n', ...
            txSweep(i), bwSweep(j));

        % Episode loop
        for slot = 1:cfg.sim.slotPerEpisode
            kernel = kernel.step(action);
        end

        report = kernel.finalize();

        % Collect
        results(idx).txOffset = txSweep(i);
        results(idx).bwScale  = bwSweep(j);
        results(idx).thr_Mbps = report.throughput_bps_total / 1e6;
        results(idx).energy_J = report.energy_J_total;
        results(idx).eff_bit_per_J = report.energy_eff_bit_per_J;
        results(idx).HO  = report.handover_count;
        results(idx).RLF = report.rlf_count;
        results(idx).drop = report.drop_total;

        fprintf("Thr=%.2f Mbps | Energy=%.2f J | Eff=%.2f | HO=%d | RLF=%d | Drop=%d\n", ...
            results(idx).thr_Mbps, ...
            results(idx).energy_J, ...
            results(idx).eff_bit_per_J, ...
            results(idx).HO, ...
            results(idx).RLF, ...
            results(idx).drop);

        idx = idx + 1;

    end
end

fprintf('\n=========== Sweep Done ===========\n');

end
