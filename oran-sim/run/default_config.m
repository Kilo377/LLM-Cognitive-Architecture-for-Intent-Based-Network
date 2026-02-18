function cfg = default_config()

    %% 仿真时间相关
    cfg.sim.slotPerEpisode = 2000;
    cfg.sim.slotDuration   = 1e-3;   % 1 ms

    %% RIC 时间尺度
    cfg.nearRT.periodSlot = 10;     % 10 ms
    cfg.nonRT.periodSlot = 1000;    % 1 s

    %% 场景参数（先占位）
    cfg.scenario.numCell = 4;
    cfg.scenario.numUE   = 30;

    %% xApp 相关
    cfg.xapp = struct();
    cfg.xapp.params = struct();

end
