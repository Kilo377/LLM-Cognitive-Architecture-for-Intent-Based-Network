function run_parameter_inf()

cfg = default_config();          % ← 改这里
offsetList = -5:1:5;

result = struct();

for k = 1:length(offsetList)

    % 每次都重建 scenario，避免状态污染
    scenario = ScenarioBuilder(cfg);
    kernel   = RanKernelNR(cfg, scenario);

    action = RanActionBus.init(cfg);
    action.handover.hysteresisOffset_dB(:) = offsetList(k);

    for t = 1:cfg.sim.slotPerEpisode
        kernel = kernel.stepWithAction(action);
    end

    report = kernel.finalize();

    result(k).offset = offsetList(k);
    result(k).ho     = report.handover_count;
    result(k).thr    = report.throughput_bps_total;
    result(k).energy = report.energy_J_total;
    result(k).ee     = report.energy_eff_bit_per_J;

    if isfield(report,'derivedKPI')
        result(k).fair = report.derivedKPI.jainFairness;
    else
        result(k).fair = NaN;
    end
end

%% Plot
figure;

subplot(2,2,1);
plot(offsetList, [result.ho], '-o');
title('HO Count'); xlabel('Hysteresis Offset');

subplot(2,2,2);
plot(offsetList, [result.thr], '-o');
title('Throughput');

subplot(2,2,3);
plot(offsetList, [result.energy], '-o');
title('Energy');

subplot(2,2,4);
plot(offsetList, [result.ee], '-o');
title('Energy Efficiency');

end
