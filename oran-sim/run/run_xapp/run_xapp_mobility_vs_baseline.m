function run_xapp_mobility_vs_baseline()

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
        "mobility_only", ["xapp_mobility_balancer"]
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

            if mod(s, 100) == 0
                fprintf('[progress][%s] slot=%d/%d\n', name, s, cfg.sim.slotPerEpisode);
            end
        end

        results.(name) = summarizeKpi(kernel.ctx.tmp.kpi);
        printLastConflict(ric, name);
    end

    printSummary(results);
    plotSummary(results, cases(:,1));
end

function printLastConflict(ric, caseName)
    if isprop(ric,'lastConflict') && ~isempty(ric.lastConflict)
        lc = ric.lastConflict;
        if isfield(lc,'domain') && lc.domain == "handover"
            fprintf("\n===== Last Handover Conflict (%s) =====\n", caseName);
            if isfield(lc,'slot')
                fprintf("slot=%d\n", lc.slot);
            end
            if isfield(lc,'field')
                fprintf("field=handover.%s\n", lc.field);
            end
            if isfield(lc,'mergeMode')
                fprintf("mergeMode=%s\n", lc.mergeMode);
            end
            if isfield(lc,'sources')
                fprintf("sources=%s\n", mat2str(string(lc.sources)));
            end
            if isfield(lc,'values')
                try
                    fprintf("values=%s\n", mat2str(lc.values));
                catch
                    fprintf("values=[%d items]\n", numel(lc.values));
                end
            end
        end
    else
        fprintf("\nNo handover conflicts detected (%s).\n", caseName);
    end
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

    fprintf("\n===== xApp Mobility vs Baseline KPI Summary =====\n");
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
    ho = zeros(n,1);
    pp = zeros(n,1);
    rlf = zeros(n,1);
    thr = zeros(n,1);
    drop = zeros(n,1);

    for i = 1:n
        r = results.(caseNames{i});
        ho(i) = r.handoverCount;
        pp(i) = r.pingPongCount;
        rlf(i) = r.rlfCount;
        thr(i) = r.throughput_Mbps;
        drop(i) = r.dropRatio;
    end

    figure('Name','xApp Mobility vs Baseline');

    subplot(2,3,1);
    bar(ho);
    title('Handover Count');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,3,2);
    bar(pp);
    title('Ping-Pong Count');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,3,3);
    bar(rlf);
    title('RLF Count');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,3,4);
    bar(thr);
    title('Throughput (Mbps)');
    grid on;
    set(gca,'XTickLabel',caseNames);

    subplot(2,3,5);
    bar(drop);
    title('Drop Ratio');
    grid on;
    set(gca,'XTickLabel',caseNames);
end
