function run_full_network_experiment()

clc; close all;

rootDir = setup_path();
cfgBase = default_config();

totalSlot = cfgBase.sim.slotPerEpisode;

%% =====================================================
% Define sweeps
%% =====================================================

powerSweep   = -10:2:10;
bwSweep      = 0.4:0.1:1.2;
energySweep  = 0.6:0.1:1.4;
boostSweep   = 0.2:0.1:0.9;

%% =====================================================
% Run experiments
%% =====================================================

run_sweep("power",   powerSweep,  cfgBase, totalSlot);
run_sweep("bw",      bwSweep,     cfgBase, totalSlot);
run_sweep("energy",  energySweep, cfgBase, totalSlot);
run_sweep("boost",   boostSweep,  cfgBase, totalSlot);

end

function run_sweep(type, values, cfgBase, totalSlot)

fprintf("\n=== Running %s sweep ===\n", type);

K = length(values);

thr  = zeros(K,1);
ene  = zeros(K,1);
sinr = zeros(K,1);
bler = zeros(K,1);
util = zeros(K,1);

for i = 1:K

    cfg = cfgBase;

    scenario = ScenarioBuilder(cfg);
    ran = RanKernelNR(cfg, scenario);

    action = build_action(type, values(i), cfg);

    for s = 1:totalSlot
        ran = ran.step(action);
    end

    state  = ran.getState();
    report = ran.finalize();
    kpi    = state.kpi;

    thr(i)  = report.throughput_bps_total/1e6;
    ene(i)  = report.energy_J_total;
    sinr(i) = kpi.meanSINR_dB;
    bler(i) = kpi.meanBLER;
    util(i) = mean(kpi.prbUtilPerCell);

end

plot_results(type, values, thr, ene, sinr, bler, util);

end

function action = build_action(type, value, cfg)

numCell = cfg.scenario.numCell;
action = struct();

switch type

    case "power"
        action.power.cellTxPowerOffset_dB = value * ones(numCell,1);

    case "bw"
        action.radio.bandwidthScale = value * ones(numCell,1);

    case "energy"
        action.energy.basePowerScale = value * ones(numCell,1);

    case "boost"
        action.scheduling.selectedUE = ones(numCell,1);
        action.scheduler.actionBoost = value;

end
end

function plot_results(type, x, thr, ene, sinr, bler, util)

figure('Name',type);

subplot(2,3,1); plot(x,thr,'-o'); title('Throughput');
subplot(2,3,2); plot(x,ene,'-o'); title('Energy');
subplot(2,3,3); plot(x,sinr,'-o'); title('SINR');
subplot(2,3,4); plot(x,bler,'-o'); title('BLER');
subplot(2,3,5); plot(x,util,'-o'); title('PRB Util');

sgtitle(type + " sweep");

end
