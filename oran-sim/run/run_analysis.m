function run_analysis()

clc;
close all;

%% =========================================
% Sweep parameters
%% =========================================
txOffsetList = [-10 0 10];          % dB
bwScaleList  = [0.5 1.0 1.5];       % scale

nTx = numel(txOffsetList);
nBw = numel(bwScaleList);

%% =========================================
% Result containers
%% =========================================
THR   = zeros(nTx,nBw);
ENER  = zeros(nTx,nBw);
EFF   = zeros(nTx,nBw);
SINR  = zeros(nTx,nBw);
P10   = zeros(nTx,nBw);
CONG  = zeros(nTx,nBw);
BLER  = zeros(nTx,nBw);
DROP  = zeros(nTx,nBw);

%% =========================================
% Sweep
%% =========================================
fprintf('\n========== Sensitivity Sweep ==========\n');

for i = 1:nTx
    for j = 1:nBw

        txOff = txOffsetList(i);
        bwSc  = bwScaleList(j);

        fprintf('\nRunning: TxOffset=%d dB, BWscale=%.2f\n', txOff, bwSc);

        cfg = default_config();
        cfg.debug.enable = false;

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);

        % build action
        action = struct();
        action.power.cellTxPowerOffset_dB = ...
            txOff * ones(cfg.scenario.numCell,1);
        action.radio.bandwidthScale = ...
            bwSc * ones(cfg.scenario.numCell,1);

        % simulate
        numSlot = 300;

        for s = 1:numSlot
            kernel = kernel.step(action);
        end

        ctx = kernel.ctx;
        kpi = ctx.tmp.kpi;

        % collect KPI
        THR(i,j)  = kpi.throughput_Mbps_total;
        ENER(i,j) = kpi.energy_J_total;
        EFF(i,j)  = kpi.energy_eff_bit_per_J;
        SINR(i,j) = kpi.meanSINR_dB;
        P10(i,j)  = kpi.p10SINR_dB;
        CONG(i,j) = kpi.congestionIndex;
        BLER(i,j) = kpi.meanBLER;
        DROP(i,j) = kpi.dropRatio;

        fprintf('Thr=%.2f Mbps | Eff=%.1f | Cong=%.2f\n', ...
            THR(i,j), EFF(i,j), CONG(i,j));
    end
end

%% =========================================
% Line plots
%% =========================================

%% 1️⃣ 固定 TxOffset，看 BW 变化
figure;
for i = 1:nTx
    subplot(2,2,1)
    plot(bwScaleList, THR(i,:), '-o', 'LineWidth', 2); hold on
    title('Throughput vs BW scale')
    xlabel('BW scale'); ylabel('Throughput (Mbps)')

    subplot(2,2,2)
    plot(bwScaleList, P10(i,:), '-o', 'LineWidth', 2); hold on
    title('p10 SINR vs BW scale')
    xlabel('BW scale'); ylabel('p10 SINR (dB)')

    subplot(2,2,3)
    plot(bwScaleList, CONG(i,:), '-o', 'LineWidth', 2); hold on
    title('Congestion vs BW scale')
    xlabel('BW scale'); ylabel('Congestion Index')

    subplot(2,2,4)
    plot(bwScaleList, EFF(i,:), '-o', 'LineWidth', 2); hold on
    title('Energy Efficiency vs BW scale')
    xlabel('BW scale'); ylabel('bit/J')
end

legend("Tx=-10","Tx=0","Tx=10")
sgtitle('Fixed TxOffset – BW Sensitivity')


%% 2️⃣ 固定 BWscale，看 TxOffset 变化
figure;
for j = 1:nBw
    subplot(2,2,1)
    plot(txOffsetList, THR(:,j), '-s', 'LineWidth', 2); hold on
    title('Throughput vs TxOffset')
    xlabel('Tx offset (dB)'); ylabel('Throughput (Mbps)')

    subplot(2,2,2)
    plot(txOffsetList, P10(:,j), '-s', 'LineWidth', 2); hold on
    title('p10 SINR vs TxOffset')
    xlabel('Tx offset (dB)'); ylabel('p10 SINR (dB)')

    subplot(2,2,3)
    plot(txOffsetList, CONG(:,j), '-s', 'LineWidth', 2); hold on
    title('Congestion vs TxOffset')
    xlabel('Tx offset (dB)'); ylabel('Congestion Index')

    subplot(2,2,4)
    plot(txOffsetList, EFF(:,j), '-s', 'LineWidth', 2); hold on
    title('Energy Efficiency vs TxOffset')
    xlabel('Tx offset (dB)'); ylabel('bit/J')
end

legend("BW=0.5","BW=1.0","BW=1.5")
sgtitle('Fixed BWscale – Tx Sensitivity')


%% 3️⃣ Pareto 曲线
figure;
for i = 1:nTx
    plot(THR(i,:), EFF(i,:), '-o', 'LineWidth', 2); hold on
end
xlabel('Throughput (Mbps)')
ylabel('Energy Efficiency (bit/J)')
title('Pareto: Throughput vs Energy Efficiency')
legend("Tx=-10","Tx=0","Tx=10")
grid on

end