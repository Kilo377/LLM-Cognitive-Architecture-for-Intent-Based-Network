function allResults = run_total_network_control_experiment()
% RUN_TOTAL_NETWORK_CONTROL_EXPERIMENT
% v1.0  总实验：对每个网络参数做 sweep，输出 KPI 曲线（参数曲线 + 时间曲线）
%
% - Static sweeps:
%   power.cellTxPowerOffset_dB
%   radio.bandwidthScale
%   energy.basePowerScale
%   sleep.cellSleepState
%
% - Dynamic scheduler sweeps (policy):
%   scheduling.selectedUE (per cell, refreshed every nearRT.periodSlot)
%
% Outputs:
%   - Figures saved under ./_results_total_exp/
%   - CSV table saved under ./_results_total_exp/summary.csv
%   - Return a table allResults

    clc;
    format long g      % 关闭 1.0e+03 * 缩放
    format compact

    rootDir = setup_path();
    cfgBase = default_config();

    % Near-RT settings (used by dynamic scheduler policy refresh)
    cfgBase.nearRT = struct();
    cfgBase.nearRT.periodSlot = 10;
    cfgBase.nearRT.xappRoot   = fullfile(rootDir,"xapps");

    totalSlot = cfgBase.sim.slotPerEpisode;

    % ---------- output dir ----------
    outDir = fullfile(pwd, "_results_total_exp");
    if ~exist(outDir, 'dir')
        mkdir(outDir);
    end

    % ---------- sampling for time curves ----------
    enableTimeCurves  = true;
    sampleEverySlot   = 20;    % 每隔多少 slot 抽样一次 state.kpi 做时间曲线
    sampleMaxPoints   = 300;   % 防止太密导致文件巨大

    % ---------- Define parameter sweeps ----------
    numCell = cfgBase.scenario.numCell;

    sweepDefs = {};

    % 1) Tx power offset sweep (dB)
    sweepDefs{end+1} = struct( ...
        "group", "power_offset_dB", ...
        "xLabel", "TxPower Offset (dB)", ...
        "values", [-10 -5 0 5 10], ...
        "type", "static", ...
        "makeAction", @(v,cfg) make_action_powerOffset(v,cfg) );

    % 2) Bandwidth scale sweep
    sweepDefs{end+1} = struct( ...
        "group", "bandwidth_scale", ...
        "xLabel", "Bandwidth Scale", ...
        "values", [0.3 0.5 0.8 1.0], ...
        "type", "static", ...
        "makeAction", @(v,cfg) make_action_bwScale(v,cfg) );

    % 3) Energy base scale sweep
    sweepDefs{end+1} = struct( ...
        "group", "energy_baseScale", ...
        "xLabel", "Energy BasePowerScale", ...
        "values", [0.6 0.8 1.0 1.1 1.3], ...
        "type", "static", ...
        "makeAction", @(v,cfg) make_action_energyScale(v,cfg) );

    % 4) Sleep state sweep (0/1/2)
    sweepDefs{end+1} = struct( ...
        "group", "sleep_state", ...
        "xLabel", "Sleep State (0/1/2)", ...
        "values", [0 1 2], ...
        "type", "static", ...
        "makeAction", @(v,cfg) make_action_sleepUniform(v,cfg) );

    % 5) Scheduler boost policy sweep (dynamic)
    %    每 periodSlot 刷新一次 selectedUE
    policyList = { ...
        struct("name","none",          "policy","none"), ...
        struct("name","firstUE",       "policy","firstUE"), ...
        struct("name","lowSINR",       "policy","lowSINR"), ...
        struct("name","longQueue",     "policy","longQueue"), ...
        struct("name","UElist_1_5_10_15_20", "policy","UElist", "ueList",[1 5 10 15 20]) ...
    };
    sweepDefs{end+1} = struct( ...
        "group", "scheduler_policy", ...
        "xLabel", "Policy Index", ...
        "values", 1:numel(policyList), ...
        "type", "dynamic", ...
        "policyList", {policyList}, ...
        "makeActionProvider", @(idx,cfg) make_actionProvider_scheduler(policyList{idx}, cfg) );

    % ---------- KPI list for plots ----------
    kpiNames = { ...
        "Thr_Mbps", "Energy_J", "MeanSINR_dB", "MeanMCS", "MeanBLER", ...
        "DropRatio", "HO", "RLF", "PRButil" ...
    };

    % ---------- Run all sweeps ----------
    allRows = [];

    fprintf("\n==============================\n");
    fprintf("Total Network Control Experiment\n");
    fprintf("==============================\n");

    for s = 1:numel(sweepDefs)

        def = sweepDefs{s};
        fprintf("\n--- Sweep Group: %s ---\n", def.group);

        sweepX = def.values(:);
        sweepY = struct(); % collect KPI vectors

        for k = 1:numel(kpiNames)
            sweepY.(kpiNames{k}) = zeros(numel(sweepX),1);
        end

        % per-case time series store (optional)
        timeSeriesStore = cell(numel(sweepX),1);
        caseLabels      = strings(numel(sweepX),1);

        for i = 1:numel(sweepX)

            v = sweepX(i);

            cfg = cfgBase;

            scenario = ScenarioBuilder(cfg);
            ran      = RanKernelNR(cfg, scenario);

            % action provider
            if strcmp(def.type, "static")
                action = def.makeAction(v, cfg);
                actionProvider = @(slot, state) action; %#ok<NASGU>
                caseLabel = sprintf("%s=%.4g", def.group, v);
            else
                % dynamic (scheduler policy)
                actionProvider = def.makeActionProvider(v, cfg);
                polName = policyList{v}.name;
                caseLabel = sprintf("%s=%s", def.group, polName);
            end

            caseLabels(i) = string(caseLabel);
            fprintf("Running: %s\n", caseLabel);

            % run episode
            [report, kpiOut, ts] = run_episode( ...
                ran, cfg, totalSlot, def, v, enableTimeCurves, sampleEverySlot, sampleMaxPoints);

            % compute derived metrics
            thr_Mbps = report.throughput_bps_total / 1e6;
            energy_J = report.energy_J_total;

            dropRatio = compute_drop_ratio(kpiOut);
            prbUtilMean = mean(kpiOut.prbUtilPerCell);

            % store sweep vectors
            sweepY.Thr_Mbps(i)    = thr_Mbps;
            sweepY.Energy_J(i)    = energy_J;
            sweepY.MeanSINR_dB(i) = kpiOut.meanSINR_dB;
            sweepY.MeanMCS(i)     = kpiOut.meanMCS;
            sweepY.MeanBLER(i)    = kpiOut.meanBLER;
            sweepY.DropRatio(i)   = dropRatio;
            sweepY.HO(i)          = kpiOut.handoverCount;
            sweepY.RLF(i)         = kpiOut.rlfCount;
            sweepY.PRButil(i)     = prbUtilMean;

            timeSeriesStore{i} = ts;

            % append one row to summary table
            row = make_summary_row(def, v, caseLabel, thr_Mbps, energy_J, kpiOut, dropRatio, prbUtilMean);
            allRows = [allRows; row]; %#ok<AGROW>

        end

        % plot KPI vs sweepX
        save_group_param_plots(outDir, def, sweepX, sweepY, caseLabels);

        % plot time curves for each KPI (optional)
        if enableTimeCurves
            save_group_time_plots(outDir, def, sweepX, timeSeriesStore, caseLabels);
        end
    end

    % ---------- Create final table ----------
    allResults = struct2table(allRows);

    % enforce nice numeric display in table preview
    disp(" ");
    disp("===== SUMMARY (first 20 rows) =====");
    disp(allResults(1:min(20,height(allResults)), :));

    % save csv
    csvPath = fullfile(outDir, "summary.csv");
    writetable(allResults, csvPath);

    fprintf("\nSaved results:\n");
    fprintf(" - %s\n", outDir);
    fprintf(" - %s\n", csvPath);

end

% ============================================================
% Episode runner
% ============================================================
function [report, kpiOut, ts] = run_episode(ran, cfg, totalSlot, def, v, enableTimeCurves, sampleEverySlot, sampleMaxPoints)

    % time series struct
    ts = struct();
    ts.t_s = [];
    ts.Thr_Mbps = [];
    ts.Energy_J = [];
    ts.MeanSINR_dB = [];
    ts.MeanMCS = [];
    ts.MeanBLER = [];
    ts.DropRatio = [];
    ts.HO = [];
    ts.RLF = [];
    ts.PRButil = [];

    % dynamic scheduler action provider
    if strcmp(def.type, "dynamic")
        actionProvider = def.makeActionProvider(v, cfg);
    else
        actionStatic = def.makeAction(v, cfg);
        actionProvider = @(slot, state) actionStatic;
    end

    sampleCount = 0;

    for slot = 1:totalSlot

        % read state only when needed
        stateNow = [];
        if strcmp(def.type, "dynamic") || (enableTimeCurves && mod(slot, sampleEverySlot)==0)
            stateNow = ran.getState();
        end

        action = actionProvider(slot, stateNow);
        ran = ran.step(action);

        % sample time curves
        if enableTimeCurves && mod(slot, sampleEverySlot)==0
            sampleCount = sampleCount + 1;
            if sampleCount <= sampleMaxPoints
                state = ran.getState();
                reportTmp = ran.finalize();  % finalize is usually "read accumulators"; if it resets in your impl, remove this line
                kpi = state.kpi;

                thr = reportTmp.throughput_bps_total/1e6;
                energy = reportTmp.energy_J_total;

                dropRatio = compute_drop_ratio(kpi);
                prbUtilMean = mean(kpi.prbUtilPerCell);

                ts.t_s(end+1,1) = state.time.t_s; %#ok<AGROW>
                ts.Thr_Mbps(end+1,1) = thr; %#ok<AGROW>
                ts.Energy_J(end+1,1) = energy; %#ok<AGROW>
                ts.MeanSINR_dB(end+1,1) = kpi.meanSINR_dB; %#ok<AGROW>
                ts.MeanMCS(end+1,1) = kpi.meanMCS; %#ok<AGROW>
                ts.MeanBLER(end+1,1) = kpi.meanBLER; %#ok<AGROW>
                ts.DropRatio(end+1,1) = dropRatio; %#ok<AGROW>
                ts.HO(end+1,1) = kpi.handoverCount; %#ok<AGROW>
                ts.RLF(end+1,1) = kpi.rlfCount; %#ok<AGROW>
                ts.PRButil(end+1,1) = prbUtilMean; %#ok<AGROW>
            end
        end
    end

    % final
    stateFinal = ran.getState();
    report = ran.finalize();
    kpiOut = stateFinal.kpi;

end

% ============================================================
% Summary row builder
% ============================================================
function row = make_summary_row(def, v, caseLabel, thr_Mbps, energy_J, kpi, dropRatio, prbUtilMean)

    row = struct();
    row.group = string(def.group);
    row.case  = string(caseLabel);

    if strcmp(def.type, "dynamic")
        row.x = double(v);
    else
        row.x = double(v);
    end

    row.Thr_Mbps    = thr_Mbps;
    row.Energy_J    = energy_J;
    row.MeanSINR_dB = kpi.meanSINR_dB;
    row.MeanMCS     = kpi.meanMCS;
    row.MeanBLER    = kpi.meanBLER;
    row.DropRatio   = dropRatio;
    row.HO          = kpi.handoverCount;
    row.RLF         = kpi.rlfCount;
    row.PRButil     = prbUtilMean;

end

% ============================================================
% KPI helpers
% ============================================================
function dropRatio = compute_drop_ratio(kpi)
    totalBits = sum(kpi.throughputBitPerUE);
    totalPkt  = totalBits + kpi.dropTotal;
    dropRatio = kpi.dropTotal / max(totalPkt,1);
end

% ============================================================
% Static action builders
% ============================================================
function action = make_action_powerOffset(offset_dB, cfg)
    numCell = cfg.scenario.numCell;
    action = struct();
    action.power.cellTxPowerOffset_dB = offset_dB * ones(numCell,1);
end

function action = make_action_bwScale(scale, cfg)
    numCell = cfg.scenario.numCell;
    action = struct();
    action.radio.bandwidthScale = scale * ones(numCell,1);
end

function action = make_action_energyScale(scale, cfg)
    numCell = cfg.scenario.numCell;
    action = struct();
    action.energy.basePowerScale = scale * ones(numCell,1);
end

function action = make_action_sleepUniform(stateVal, cfg)
    numCell = cfg.scenario.numCell;
    action = struct();
    action.sleep.cellSleepState = stateVal * ones(numCell,1);
end

% ============================================================
% Dynamic scheduler policy: action provider
% ============================================================
function actionProvider = make_actionProvider_scheduler(policySpec, cfg)
    % actionProvider(slot, state) -> action struct
    numCell = cfg.scenario.numCell;
    periodSlot = cfg.nearRT.periodSlot;

    % persistent selectedUE (hold value between refresh)
    selHold = zeros(numCell,1);

    actionProvider = @provider;

    function action = provider(slot, state)

        % refresh every periodSlot OR if selHold never set
        needRefresh = (mod(slot-1, periodSlot) == 0);

        if needRefresh
            if isempty(state)
                % state should be passed by caller for dynamic cases
                selHold = zeros(numCell,1);
            else
                selHold = pick_selectedUE(policySpec, state, cfg);
            end
        end

        action = struct();
        action.scheduling.selectedUE = selHold;

    end
end

function sel = pick_selectedUE(policySpec, state, cfg)

    numCell = cfg.scenario.numCell;
    numUE   = cfg.scenario.numUE;

    sel = zeros(numCell,1);

    if ~isfield(state,'ue') || ~isfield(state.ue,'servingCell')
        return;
    end

    serving = state.ue.servingCell(:);

    % Optional features
    hasSINR  = isfield(state.ue,'sinr_dB') && numel(state.ue.sinr_dB) == numUE;
    hasQ     = isfield(state.ue,'buffer_bits') && numel(state.ue.buffer_bits) == numUE;

    sinr = [];
    qbits = [];
    if hasSINR, sinr = state.ue.sinr_dB(:); end
    if hasQ,    qbits = state.ue.buffer_bits(:); end

    for c = 1:numCell

        ueSet = find(serving == c);
        if isempty(ueSet)
            sel(c) = 0;
            continue;
        end

        pol = string(policySpec.policy);

        if pol == "none"
            sel(c) = 0;

        elseif pol == "firstUE"
            sel(c) = ueSet(1);

        elseif pol == "lowSINR"
            if ~hasSINR
                sel(c) = ueSet(1);
            else
                [~,ix] = min(sinr(ueSet));
                sel(c) = ueSet(ix);
            end

        elseif pol == "longQueue"
            if ~hasQ
                sel(c) = ueSet(1);
            else
                [~,ix] = max(qbits(ueSet));
                sel(c) = ueSet(ix);
            end

        elseif pol == "UElist"
            if isfield(policySpec,'ueList') && ~isempty(policySpec.ueList)
                lst = policySpec.ueList(:);
                lst = lst(lst>=1 & lst<=numUE);
                hit = intersect(ueSet, lst, 'stable');
                if ~isempty(hit)
                    sel(c) = hit(1);
                else
                    sel(c) = 0;
                end
            else
                sel(c) = 0;
            end
        else
            sel(c) = 0;
        end
    end
end

% ============================================================
% Plotting
% ============================================================
function save_group_param_plots(outDir, def, sweepX, sweepY, caseLabels)

    groupDir = fullfile(outDir, string(def.group));
    if ~exist(groupDir,'dir'), mkdir(groupDir); end

    % choose X for labels
    x = sweepX(:);

    % for scheduler policy, x-axis should be categorical names
    isPolicy = strcmp(def.type, "dynamic");

    % plot each KPI vs parameter
    fns = fieldnames(sweepY);
    for i = 1:numel(fns)
        kpiName = fns{i};

        fig = figure('Visible','off');
        y = sweepY.(kpiName);

        if ~isPolicy
            plot(x, y, '-o');
            xlabel(def.xLabel);
            xlim([min(x) max(x)]);
        else
            % use index on x-axis but show names in ticks
            plot(x, y, '-o');
            xlabel("Policy");
            xticks(x);
            xticklabels(caseLabels);
            xtickangle(25);
        end

        ylabel(kpiName);
        title(sprintf("%s: %s vs %s", def.group, kpiName, def.xLabel), 'Interpreter','none');
        grid on;

        saveas(fig, fullfile(groupDir, sprintf("param_%s.png", kpiName)));
        close(fig);
    end

end

function save_group_time_plots(outDir, def, sweepX, timeSeriesStore, caseLabels)

    groupDir = fullfile(outDir, string(def.group));
    if ~exist(groupDir,'dir'), mkdir(groupDir); end

    % pick a subset of time KPIs to avoid too many plots
    timeKpis = { "Thr_Mbps", "Energy_J", "MeanSINR_dB", "DropRatio", "PRButil" };

    for kk = 1:numel(timeKpis)

        kpiName = timeKpis{kk};

        fig = figure('Visible','off');
        hold on;

        for i = 1:numel(sweepX)

            ts = timeSeriesStore{i};
            if isempty(ts) || ~isfield(ts,'t_s') || isempty(ts.t_s)
                continue;
            end
            if ~isfield(ts, kpiName)
                continue;
            end

            plot(ts.t_s, ts.(kpiName));
        end

        xlabel("Time (s)");
        ylabel(kpiName);
        title(sprintf("%s: %s vs time", def.group, kpiName), 'Interpreter','none');
        grid on;

        legend(caseLabels, 'Interpreter','none', 'Location','best');
        hold off;

        saveas(fig, fullfile(groupDir, sprintf("time_%s.png", kpiName)));
        close(fig);
    end

end
