function run_xapp_throughput_vs_baseline()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    rootDir = setup_path();

    cfg = default_config();
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 2000;
    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");

    cases = {
        "baseline", [];
        "throughput_only", ["xapp_throughput_maximizer"]
    };

    results = struct();

    for ci = 1:size(cases,1)
        name = cases{ci,1};
        xset = cases{ci,2};

        fprintf("\n=== xApp Compare Case: %s ===\n", name);

        scenario = ScenarioBuilder(cfg);
        kernel   = RanKernelNR(cfg, scenario);
        ric      = NearRTRIC(cfg, "xappSet", xset);

        for s = 1:cfg.sim.slotPerEpisode
            state = kernel.ctx.state;
            [ric, action, ~] = ric.step(state);
            kernel = kernel.step(action);

            if mod(s, 200) == 0
                fprintf('[progress][%s] slot=%d/%d\n', name, s, cfg.sim.slotPerEpisode);
            end
        end

        results.(name) = summarizeKpi(kernel.ctx.tmp.kpi);
    end

    printSummary(results);
    plotSummary(results, cases(:,1));
end

function out = summarizeKpi(kpi)

    out = struct();
    out.throughput_Mbps = kpi.capacity.throughput_Mbps_total;
    out.dropRatio = kpi.reliability.dropRatio;
    out.meanBLER = kpi.reliability.meanBLER;
    out.handoverCount = kpi.stability.handoverCount;
    out.pingPongCount = kpi.stability.pingPongCount;
    out.rlfCount = kpi.reliability.rlfCount;
end

function printSummary(results)

    names = fieldnames(results);

    fprintf("\n===== xApp Throughput Maximizer vs Baseline KPI Summary =====\n");
    fprintf("Case                    Thr(Mbps)  DropRatio  BLER     HOcnt  PingPong  RLF\n");

    for i = 1:numel(names)
        r = results.(names{i});
        fprintf("%-22s %9.2f  %8.4f  %7.4f  %5d  %8d  %3d\n", ...
            names{i}, r.throughput_Mbps, r.dropRatio, r.meanBLER, ...
            r.handoverCount, r.pingPongCount, r.rlfCount);
    end
end

function plotSummary(results, caseNames)

    n = numel(caseNames);
    thr = zeros(n,1);
    drop = zeros(n,1);

    for i = 1:n
        r = results.(caseNames{i});
        thr(i) = r.throughput_Mbps;
        drop(i) = r.dropRatio;
    end

    figure('Name','xApp Throughput Maximizer vs Baseline');

    subplot(1,2,1);
    bar(thr);
    title('Throughput (Mbps)');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(1,2,2);
    bar(drop);
    title('Drop Ratio');
    grid on;
    set(gca,'XTickLabel',caseNames);
end
