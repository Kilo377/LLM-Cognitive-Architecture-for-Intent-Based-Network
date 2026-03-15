function run_nonrt_demo()

    if exist('setup_path','file') ~= 2
        runDir = fileparts(mfilename('fullpath'));
        addpath(fullfile(runDir,'..'));
    end

    rootDir = setup_path();

    cfg = default_config();
    cfg.debug.enable = false;
    cfg.sim.slotPerEpisode = 2000;

    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");
    cfg.nonRT.triggerTime_s = 1.0;
    cfg.debug.enableNonRT = true;
    cfg.debug.nonRTEvery = 100;
    cfg.nonRT.timeout_s = 2;

    scenario = ScenarioBuilder(cfg);
    kernel   = RanKernelNR(cfg, scenario);
    ric      = NearRTRIC(cfg, "xappSet", []);
    nonrt    = NonRTRIC(cfg);

    slotCount = cfg.sim.slotPerEpisode;
    t_s = zeros(slotCount,1);
    thr_Mbps = nan(slotCount,1);
    dropRatio = nan(slotCount,1);

    for s = 1:slotCount
        state = kernel.ctx.state;
        [ric, action, ~] = ric.step(state);
        kernel = kernel.step(action);

        t_s(s) = kernel.ctx.slot * kernel.ctx.dt;
        if isfield(kernel.ctx.tmp,'kpi') && isfield(kernel.ctx.tmp.kpi,'capacity') && ...
                isfield(kernel.ctx.tmp.kpi.capacity,'throughput_Mbps_total')
            thr_Mbps(s) = kernel.ctx.tmp.kpi.capacity.throughput_Mbps_total;
        end
        if isfield(kernel.ctx.tmp,'kpi') && isfield(kernel.ctx.tmp.kpi,'reliability') && ...
                isfield(kernel.ctx.tmp.kpi.reliability,'dropRatio')
            dropRatio(s) = kernel.ctx.tmp.kpi.reliability.dropRatio;
        end

        if cfg.debug.enableNonRT && mod(kernel.ctx.slot, cfg.debug.nonRTEvery) == 0
            fprintf('[RUN] slot=%d t_s=%.3f\n', kernel.ctx.slot, kernel.ctx.slot * kernel.ctx.dt);
        end

        %#ok<NASGU>
        [nonrt, ric, ~] = nonrt.step(kernel.ctx, ric);
    end

    triggerSlot = max(1, round(cfg.nonRT.triggerTime_s / cfg.sim.slotDuration));
    preIdx = 1:min(triggerSlot, slotCount);
    postIdx = min(triggerSlot+1, slotCount):slotCount;

    preThr = mean(thr_Mbps(preIdx), 'omitnan');
    postThr = mean(thr_Mbps(postIdx), 'omitnan');
    preDrop = mean(dropRatio(preIdx), 'omitnan');
    postDrop = mean(dropRatio(postIdx), 'omitnan');

    fprintf('\n===== Non-RT Policy Effect (Demo) =====\n');
    fprintf('Trigger slot: %d (t=%.3fs)\n', triggerSlot, triggerSlot * cfg.sim.slotDuration);
    fprintf('Throughput (Mbps): pre=%.2f, post=%.2f\n', preThr, postThr);
    fprintf('DropRatio: pre=%.4f, post=%.4f\n', preDrop, postDrop);

    figure('Name','Non-RT Policy Effect');
    tiledlayout(2,1);

    nexttile;
    plot(t_s, thr_Mbps, 'LineWidth', 1.4);
    xline(cfg.nonRT.triggerTime_s, '--r', 'Trigger');
    ylabel('Throughput (Mbps)');
    grid on;

    nexttile;
    plot(t_s, dropRatio, 'LineWidth', 1.4);
    xline(cfg.nonRT.triggerTime_s, '--r', 'Trigger');
    ylabel('DropRatio');
    xlabel('Time (s)');
    grid on;
end
