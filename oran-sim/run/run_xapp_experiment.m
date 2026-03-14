
function run_xapp_experiment()

    rootDir = setup_path();

    cfg = default_config();
    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    totalSlot = cfg.sim.slotPerEpisode;

    cases = {
        "baseline", [];
        "capacity_only", ["xapp_capacity_extreme"];
        "energy_only", ["xapp_energy_aggressive"];
        "both", ["xapp_capacity_extreme","xapp_energy_aggressive"]
    };

    results = struct();

    for ci = 1:size(cases,1)

        name = cases{ci,1};
        xset = cases{ci,2};

        fprintf("\n=== Running %s ===\n", name);

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);

        ric = NearRTRIC(cfg, "xappSet", xset);

        thr = zeros(totalSlot,1);
        bitperj = zeros(totalSlot,1);
        cong = zeros(totalSlot,1);

        for s = 1:totalSlot

            % 1️⃣ 取当前 state
            state = kernel.ctx.state;

            % 2️⃣ RIC 生成 action
            [ric, action, ~] = ric.step(state);

            % 3️⃣ Kernel 推进
            kernel = kernel.step(action);

            % 4️⃣ 读取 KPI
            kpi = kernel.ctx.tmp.kpi;

            thr(s) = kpi.capacity.throughput_Mbps_total;
            bitperj(s) = kpi.efficiency.bitPerJ;
            cong(s) = kpi.system.congestionIndex;

        end

        results.(name).thr = thr;
        results.(name).bitperj = bitperj;
        results.(name).cong = cong;

    end

    %% Plot Throughpt
    figure; hold on;
    
    N = length(results.baseline.thr);
    idx1 = 1:15:N;
    idx2 = 5:15:N;
    idx3 = 8:15:N;
    idx4 = 12:15:N;
    
    plot(results.baseline.thr, ...
        'LineWidth',1.8, ...
        'Color',[0 0.6 1], ...
        'Marker','o', ...
        'MarkerIndices',idx1);
    
    plot(results.capacity_only.thr, ...
        'LineWidth',1.8, ...
        'Color',[1 0.4 0], ...
        'Marker','s', ...
        'MarkerIndices',idx2);
    
    plot(results.energy_only.thr, ...
        'LineWidth',1.8, ...
        'Color',[0 0.8 0.2], ...
        'Marker','^', ...
        'MarkerIndices',idx3);
    
    plot(results.both.thr, ...
        'LineWidth',1.8, ...
        'Color',[0.8 0 0.8], ...
        'Marker','*', ...
        'MarkerIndices',idx4);
    
    legend("baseline","capacity","energy","both");
    title("Throughput (Mbps)");
    grid on;
    hold off;

    %% Plot BitPerJ
    figure; hold on;
    
    plot(results.baseline.bitperj, ...
        'LineWidth',1.8, ...
        'Color',[0 0.6 1], ...
        'Marker','o', ...
        'MarkerIndices',idx1);
    
    plot(results.capacity_only.bitperj, ...
        'LineWidth',1.8, ...
        'Color',[1 0.4 0], ...
        'Marker','s', ...
        'MarkerIndices',idx2);
    
    plot(results.energy_only.bitperj, ...
        'LineWidth',1.8, ...
        'Color',[0 0.8 0.2], ...
        'Marker','^', ...
        'MarkerIndices',idx3);
    
    plot(results.both.bitperj, ...
        'LineWidth',1.8, ...
        'Color',[0.8 0 0.8], ...
        'Marker','*', ...
        'MarkerIndices',idx4);
    
    legend("baseline","capacity","energy","both");
    title("Bit per Joule");
    grid on;
    hold off;

    %% Plot Congestion
    figure; hold on;
    
    plot(results.baseline.cong, ...
        'LineWidth',1.8, ...
        'Color',[0 0.6 1], ...
        'Marker','o', ...
        'MarkerIndices',idx1);
    
    plot(results.capacity_only.cong, ...
        'LineWidth',1.8, ...
        'Color',[1 0.4 0], ...
        'Marker','s', ...
        'MarkerIndices',idx2);
    
    plot(results.energy_only.cong, ...
        'LineWidth',1.8, ...
        'Color',[0 0.8 0.2], ...
        'Marker','^', ...
        'MarkerIndices',idx3);
    
    plot(results.both.cong, ...
        'LineWidth',1.8, ...
        'Color',[0.8 0 0.8], ...
        'Marker','*', ...
        'MarkerIndices',idx4);
    
    legend("baseline","capacity","energy","both");
    title("Congestion Index");
    grid on;
    hold off;

end