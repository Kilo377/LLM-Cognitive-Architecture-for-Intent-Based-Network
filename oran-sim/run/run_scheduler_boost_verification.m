function run_scheduler_boost_verification()

    clc;
    rootDir = setup_path();
    cfg     = default_config();

    totalSlot = cfg.sim.slotPerEpisode;

    fprintf('\n========== Scheduler Boost Verification ==========\n');

    %---------------------------------------
    % 1) Run baseline
    %---------------------------------------
    fprintf('\nRunning baseline...\n');
    [prbBase, ueList] = run_case(cfg, totalSlot, []);

    %---------------------------------------
    % 2) Run boost (example: boost UE 1)
    %---------------------------------------
    boostUE = 1;

    fprintf('\nRunning boost UE %d ...\n', boostUE);
    [prbBoost, ~] = run_case(cfg, totalSlot, boostUE);

    %---------------------------------------
    % 3) Compute average PRB per UE
    %---------------------------------------
    avgBase  = mean(prbBase,2);
    avgBoost = mean(prbBoost,2);

    fprintf('\nUE   AvgPRB(Base)   AvgPRB(Boost)\n');
    fprintf('------------------------------------\n');

    for u = 1:length(ueList)
        fprintf('%-4d %-14.4f %-14.4f\n', ...
            u, avgBase(u), avgBoost(u));
    end

    fprintf('\nBoosted UE %d difference: %.4f PRB per slot\n', ...
        boostUE, avgBoost(boostUE) - avgBase(boostUE));

    fprintf('\n==================================================\n');
end

function [prbPerUE, ueList] = run_case(cfg, totalSlot, boostUE)

    scenario = ScenarioBuilder(cfg);
    ran      = RanKernelNR(cfg, scenario);

    numUE   = cfg.scenario.numUE;
    numCell = cfg.scenario.numCell;

    prbPerUE = zeros(numUE, totalSlot);

    for slot = 1:totalSlot

        %-----------------------------------
        % Build action
        %-----------------------------------
        action = struct();

        if ~isempty(boostUE)
            action.scheduling.selectedUE = boostUE * ones(numCell,1);
        end

        %-----------------------------------
        % Step RAN
        %-----------------------------------
        ran = ran.step(action);

        %-----------------------------------
        % Extract PRB allocation
        %-----------------------------------
        ctx = ran.ctx;

        if isfield(ctx.tmp,'scheduledUE')

            for c = 1:numCell

                ueListCell = ctx.tmp.scheduledUE{c};
                prbAlloc   = ctx.tmp.prbAlloc{c};

                if isempty(ueListCell)
                    continue;
                end

                for i = 1:length(ueListCell)

                    u = ueListCell(i);
                    prbPerUE(u,slot) = ...
                        prbPerUE(u,slot) + prbAlloc(i);

                end
            end
        end
    end

    ueList = 1:numUE;
end
