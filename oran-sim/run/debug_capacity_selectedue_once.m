function debug_capacity_selectedue_once()

    rootDir = setup_path();

    cfg = default_config();
    cfg.nearRT.xappRoot = fullfile(rootDir, "xapps");
    cfg.sim.slotPerEpisode = 5;

    scenario = ScenarioBuilder(cfg);
    kernel   = RanKernelNR(cfg, scenario);

    ric = NearRTRIC(cfg, "xappSet", ["xapp_capacity_extreme"]);

    for s = 1:cfg.sim.slotPerEpisode

        state = kernel.ctx.state;

        [ric, action, ~] = ric.step(state);

        action.debug.enableVerbose = true;
        action.debug.printSlot = s;

        kernel = kernel.step(action);

        
        [ric, action, info] = ric.step(state);
        disp(info.actionSource)

        % 关键观察点
        if isfield(action,'scheduling') && isfield(action.scheduling,'selectedUE')
            disp("[CHECK] action.scheduling.selectedUE exists");
            disp(action.scheduling.selectedUE);
        else
            disp("[CHECK] action.scheduling.selectedUE missing");
        end

        if isfield(kernel.ctx,'ctrl') && isfield(kernel.ctx.ctrl,'selectedUE')
            disp("[CHECK] ctx.ctrl.selectedUE exists");
            disp(kernel.ctx.ctrl.selectedUE);
        else
            disp("[CHECK] ctx.ctrl.selectedUE missing");
        end

        

    end
end