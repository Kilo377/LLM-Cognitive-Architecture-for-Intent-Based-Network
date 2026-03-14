
function run_conflict_demo()

    rootDir = setup_path();

    cfg = default_config();
    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    totalSlot = cfg.sim.slotPerEpisode;

    cases = {
        "baseline", [];
        "reliability_only", ["xapp_reliability_strict"];
        "energy_only", ["xapp_energy_aggressive"];
        "reliability_energy", ...
            ["xapp_reliability_strict","xapp_energy_aggressive"]
    };

    results = struct();

    for ci = 1:size(cases,1)

        name = cases{ci,1};
        xset = cases{ci,2};

        fprintf("\n=== Running %s ===\n", name);

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);
        ric      = NearRTRIC(cfg, "xappSet", xset);

        thr     = zeros(totalSlot,1);
        bitperj = zeros(totalSlot,1);
        bler    = zeros(totalSlot,1);
        p10sinr = zeros(totalSlot,1);

        for s = 1:totalSlot

            state = kernel.ctx.state;

            [ric, action, ~] = ric.step(state);
            kernel = kernel.step(action);

            kpi = kernel.ctx.tmp.kpi;

            thr(s)     = kpi.capacity.throughput_Mbps_total;
            bitperj(s) = kpi.efficiency.bitPerJ;
            bler(s)    = kpi.reliability.meanBLER;
            p10sinr(s) = kpi.phy.p10SINR_dB;

        end

        results.(name).thr     = thr;
        results.(name).bitperj = bitperj;
        results.(name).bler    = bler;
        results.(name).p10sinr = p10sinr;

    end

    %% ===============================
    % 1️⃣ Reliability Conflict
    %% ===============================
    figure; hold on;

    plot(results.baseline.bler, ...
        'Color',[0.2 0.6 1],'LineWidth',1.8);

    plot(results.reliability_only.bler, ...
        'Color',[0.9 0.2 0.2],'LineWidth',1.8);

    plot(results.reliability_energy.bler, ...
        'Color',[0.2 0.8 0.4],'LineWidth',1.8);

    legend("baseline","reliability_only","reliability+energy");
    title("Reliability KPI Conflict: BLER");
    grid on;
    hold off;


    %% ===============================
    % 2️⃣ Energy Conflict
    %% ===============================
    figure; hold on;

    plot(results.baseline.bitperj, ...
        'Color',[0.2 0.6 1],'LineWidth',1.8);

    plot(results.energy_only.bitperj, ...
        'Color',[0.8 0.3 0.9],'LineWidth',1.8);

    plot(results.reliability_energy.bitperj, ...
        'Color',[1 0.5 0.1],'LineWidth',1.8);

    legend("baseline","energy_only","reliability+energy");
    title("Energy KPI Conflict: Bit per Joule");
    grid on;
    hold off;


    %% ===============================
    % 3️⃣ Capacity Side Effect
    %% ===============================
    figure; hold on;

    plot(results.baseline.thr, ...
        'Color',[0.2 0.6 1],'LineWidth',1.8);

    plot(results.reliability_only.thr, ...
        'Color',[0.9 0.2 0.2],'LineWidth',1.8);

    plot(results.energy_only.thr, ...
        'Color',[0.8 0.3 0.9],'LineWidth',1.8);

    plot(results.reliability_energy.thr, ...
        'Color',[0.2 0.8 0.4],'LineWidth',1.8);

    legend("baseline","reliability_only","energy_only","reliability+energy");
    title("Throughput Side Effect under Conflict");
    grid on;
    hold off;


    %% ===============================
    % 4️⃣ Pareto Snapshot (Final Slot)
    %% ===============================
    figure; hold on;

    names = fieldnames(results);

    colors = [
        0.2 0.6 1;
        0.9 0.2 0.2;
        0.8 0.3 0.9;
        0.2 0.8 0.4
    ];

    for i = 1:length(names)

        n = names{i};

        x = results.(n).thr(end);
        y = results.(n).bitperj(end);

        scatter(x, y, 120, ...
            'MarkerFaceColor', colors(i,:), ...
            'MarkerEdgeColor','k');

        text(x, y, "  "+n);

    end

    xlabel("Throughput (Mbps)");
    ylabel("Bit per Joule");
    title("Pareto Tradeoff under Conflict");
    grid on;
    hold off;

end