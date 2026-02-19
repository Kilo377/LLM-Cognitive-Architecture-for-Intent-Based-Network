function run_total_experiment_visualize(summaryTable)

    clc;
    close all;

    % ==========================
    % 自动读取 CSV
    % ==========================
    if nargin == 0

        rootDir = setup_path();
        filePath = fullfile(rootDir, "_results_total_exp", "summary.csv");

        if ~isfile(filePath)
            error("summary.csv not found. Run total experiment first.");
        end

        summaryTable = readtable(filePath, ...
            'VariableNamingRule','preserve');
    end

    if istable(summaryTable) == 0
        error("Input must be a table.");
    end

    % ==========================
    % 类型安全处理
    % ==========================
    if iscell(summaryTable.group)
        summaryTable.group = string(summaryTable.group);
    end

    if iscategorical(summaryTable.group)
        summaryTable.group = string(summaryTable.group);
    end

    groups = unique(summaryTable.group);

    kpiList = {
        "Thr_Mbps"
        "Energy_J"
        "MeanSINR_dB"
        "MeanMCS"
        "MeanBLER"
        "DropRatio"
        "PRButil"
        };

    fprintf("\n========== VISUALIZATION ==========\n");

    % ==========================
    % 循环每一组参数
    % ==========================
    for g = 1:length(groups)

        groupName = groups(g);

        % 安全筛选
        idx = strcmp(summaryTable.group, groupName);
        dataGroup = summaryTable(idx, :);

        x = dataGroup.x;

        [xSorted, order] = sort(x);
        dataGroup = dataGroup(order,:);

        fprintf("Plotting group: %s\n", groupName);

        % ======================
        % 每个 KPI 单独画图
        % ======================
        for k = 1:length(kpiList)

            kpiName = kpiList{k};

            if ~ismember(kpiName, summaryTable.Properties.VariableNames)
                continue;
            end

            y = dataGroup.(kpiName);

            figure;
            plot(xSorted, y, '-o', 'LineWidth', 2);
            grid on;

            xlabel(groupName, 'Interpreter','none');
            ylabel(kpiName, 'Interpreter','none');
            title([char(groupName) " → " char(kpiName)], ...
                'Interpreter','none');
        end
    end

    fprintf("\nAll plots generated successfully.\n");
end
