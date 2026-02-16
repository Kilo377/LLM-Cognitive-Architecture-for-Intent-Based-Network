function run_visual_congestion()

    close all;

    %% ============================
    % Config
    %% ============================
    cfg = default_config();

    % 调整规模（可改）
    cfg.scenario.numUE = 40;
    cfg.sim.slotPerEpisode = 3000;

    %% ============================
    % Build
    %% ============================
    scenario = ScenarioBuilder(cfg);
    ran      = RanKernelNR(cfg, scenario);

    totalSlot = cfg.sim.slotPerEpisode;

    %% ============================
    % Logging buffers
    %% ============================
    prbUtil_log   = zeros(totalSlot,1);
    buffer_log    = zeros(totalSlot,1);
    drop_log      = zeros(totalSlot,1);
    throughput_log = zeros(totalSlot,1);

    %% ============================
    % Main loop (baseline)
    %% ============================
    for t = 1:totalSlot

        ran = ran.step([]);  % baseline

        state = ran.getState();

        prbUtil_log(t) = mean(state.kpi.prbUtilPerCell);
        buffer_log(t)  = mean(state.ue.buffer_bits);
        drop_log(t)    = state.kpi.dropTotal;

        totalBits = sum(state.kpi.throughputBitPerUE);
        throughput_log(t) = totalBits / (t * cfg.sim.slotDuration);
    end

    %% ============================
    % Plot
    %% ============================
    figure('Name','Congestion Analysis','Position',[100 100 900 700]);

    subplot(4,1,1);
    plot(prbUtil_log,'LineWidth',1.5);
    ylabel('PRB Util');
    ylim([0 1.1]);
    grid on;
    title('PRB Utilization');

    subplot(4,1,2);
    plot(buffer_log,'LineWidth',1.5);
    ylabel('Avg Buffer (bits)');
    grid on;
    title('Average UE Buffer');

    subplot(4,1,3);
    plot(drop_log,'LineWidth',1.5);
    ylabel('Drop Total');
    grid on;
    title('Total Drops');

    subplot(4,1,4);
    plot(throughput_log/1e6,'LineWidth',1.5);
    ylabel('Throughput (Mbps)');
    xlabel('Slot');
    grid on;
    title('Running Throughput');

end
