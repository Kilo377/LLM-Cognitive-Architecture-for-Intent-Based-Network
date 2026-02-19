function T = run_2d_sweep_power_bw()
% 2D sweep: power_offset_dB x bandwidth_scale
%
% Outputs:
%   - T (table) all points
%   - saves CSV to _results_2d/power_bw.csv
%   - plots heatmaps for key KPIs
%
% Notes:
%   - Uses format long g to avoid 1.0e+03 * display.
%   - Each grid point runs one full episode.
%   - You can increase repeatN and average for stability.

    clc;
    format long g
    format compact

    rootDir = setup_path();
    cfgBase = default_config();

    cfgBase.nearRT = struct();
    cfgBase.nearRT.periodSlot = 10;
    cfgBase.nearRT.xappRoot = fullfile(rootDir,"xapps");

    totalSlot = cfgBase.sim.slotPerEpisode;

    %==============================
    % 2D grid definition
    %==============================
    powerGrid_dB = [-10 -5 0 5 10];         % X axis
    bwGrid       = [0.3 0.5 0.8 1.0];       % Y axis

    % optional repeats for each point
    repeatN = 1;

    %==============================
    % Run sweep
    %==============================
    rows = [];
    fprintf("\n=========== 2D Sweep: power_offset_dB x bandwidth_scale ===========\n");
    fprintf("Grid: %d x %d (repeat=%d)\n\n", numel(powerGrid_dB), numel(bwGrid), repeatN);

    for i = 1:numel(powerGrid_dB)
        for j = 1:numel(bwGrid)

            p = powerGrid_dB(i);
            b = bwGrid(j);

            fprintf("Running: power=%g dB, bw=%g ...\n", p, b);

            % accumulate repeats
            acc = init_acc();

            for r = 1:repeatN

                cfg = cfgBase;
                scenario = ScenarioBuilder(cfg);
                ran      = RanKernelNR(cfg, scenario);

                action = struct();
                action.power.cellTxPowerOffset_dB = p * ones(cfg.scenario.numCell,1);
                action.radio.bandwidthScale       = b * ones(cfg.scenario.numCell,1);

                for slot = 1:totalSlot
                    ran = ran.step(action);
                end

                state  = ran.getState();
                report = ran.finalize();
                kpi    = state.kpi;

                [dropRatio, prbUtilMean] = derive_kpi(kpi);

                acc = acc_add(acc, report, kpi, dropRatio, prbUtilMean);
            end

            out = acc_finalize(acc, repeatN);

            rows = [rows;
                { "power_bw", ...
                  sprintf("power=%g,bw=%g", p, b), ...
                  p, b, ...
                  out.Thr_Mbps, out.Energy_J, out.MeanSINR_dB, out.MeanMCS, out.MeanBLER, ...
                  out.DropRatio, out.HO, out.RLF, out.PRButil }]; %#ok<AGROW>
        end
    end

    T = cell2table(rows, ...
        'VariableNames', {'group','case','power_dB','bw_scale', ...
                          'Thr_Mbps','Energy_J','MeanSINR_dB','MeanMCS','MeanBLER', ...
                          'DropRatio','HO','RLF','PRButil'});

    %==============================
    % Save
    %==============================
    outDir = fullfile(rootDir, "_results_2d");
    if ~exist(outDir,'dir'); mkdir(outDir); end
    outCsv = fullfile(outDir, "power_bw.csv");
    writetable(T, outCsv);

    fprintf("\nSaved: %s\n", outCsv);

    %==============================
    % Plot heatmaps
    %==============================
    plot_heatmap(T, powerGrid_dB, bwGrid, "Thr_Mbps",  "Throughput (Mbps)");
    plot_heatmap(T, powerGrid_dB, bwGrid, "Energy_J",  "Energy (J)");
    plot_heatmap(T, powerGrid_dB, bwGrid, "PRButil",   "PRB Utilization");
    plot_heatmap(T, powerGrid_dB, bwGrid, "DropRatio", "Drop Ratio");

    fprintf("\n===============================================================\n\n");
end

%==================================================================
% Helpers
%==================================================================
function [dropRatio, prbUtilMean] = derive_kpi(kpi)
    totalBits = sum(kpi.throughputBitPerUE);
    totalPkt  = totalBits + kpi.dropTotal;
    dropRatio = kpi.dropTotal / max(totalPkt,1);
    prbUtilMean = mean(kpi.prbUtilPerCell);
end

function acc = init_acc()
    acc.Thr_Mbps    = 0;
    acc.Energy_J    = 0;
    acc.MeanSINR_dB = 0;
    acc.MeanMCS     = 0;
    acc.MeanBLER    = 0;
    acc.DropRatio   = 0;
    acc.HO          = 0;
    acc.RLF         = 0;
    acc.PRButil     = 0;
end

function acc = acc_add(acc, report, kpi, dropRatio, prbUtilMean)
    acc.Thr_Mbps    = acc.Thr_Mbps    + report.throughput_bps_total/1e6;
    acc.Energy_J    = acc.Energy_J    + report.energy_J_total;
    acc.MeanSINR_dB = acc.MeanSINR_dB + kpi.meanSINR_dB;
    acc.MeanMCS     = acc.MeanMCS     + kpi.meanMCS;
    acc.MeanBLER    = acc.MeanBLER    + kpi.meanBLER;
    acc.DropRatio   = acc.DropRatio   + dropRatio;
    acc.HO          = acc.HO          + kpi.handoverCount;
    acc.RLF         = acc.RLF         + kpi.rlfCount;
    acc.PRButil     = acc.PRButil     + prbUtilMean;
end

function out = acc_finalize(acc, N)
    out.Thr_Mbps    = acc.Thr_Mbps / N;
    out.Energy_J    = acc.Energy_J / N;
    out.MeanSINR_dB = acc.MeanSINR_dB / N;
    out.MeanMCS     = acc.MeanMCS / N;
    out.MeanBLER    = acc.MeanBLER / N;
    out.DropRatio   = acc.DropRatio / N;
    out.HO          = round(acc.HO / N);
    out.RLF         = round(acc.RLF / N);
    out.PRButil     = acc.PRButil / N;
end

function plot_heatmap(T, xGrid, yGrid, fieldName, titleStr)
    % Build matrix Z(j,i): rows=y(bw), cols=x(power)
    Z = nan(numel(yGrid), numel(xGrid));

    for i = 1:numel(xGrid)
        for j = 1:numel(yGrid)
            p = xGrid(i);
            b = yGrid(j);

            idx = (T.power_dB == p) & (abs(T.bw_scale - b) < 1e-12);
            if any(idx)
                Z(j,i) = T{find(idx,1,'first'), fieldName};
            end
        end
    end

    figure('Name', titleStr);
    imagesc(xGrid, yGrid, Z);
    set(gca,'YDir','normal');
    xlabel('power\_offset\_dB');
    ylabel('bandwidth\_scale');
    title(titleStr);
    colorbar;

    % annotate values
    for j = 1:size(Z,1)
        for i = 1:size(Z,2)
            if isfinite(Z(j,i))
                text(xGrid(i), yGrid(j), sprintf('%.3g', Z(j,i)), ...
                    'HorizontalAlignment','center', 'FontSize', 9);
            end
        end
    end
end
