function scenario = ScenarioBuilder(cfg)
%SCENARIOBUILDER Build 5G NR simulation scenario
%   Output:
%     scenario: struct containing topology, mobility, traffic, channel

    fprintf('[ScenarioBuilder] Build scenario\n');

    %% ===============================
    % 1. 基本仿真参数
    %% ===============================
    scenario.sim.slotDuration = cfg.sim.slotDuration;
    scenario.sim.numSlot      = cfg.sim.slotPerEpisode;

    %% ===============================
    % 2. 网络拓扑
    %% ===============================
    scenario.topology.numCell = cfg.scenario.numCell;
    scenario.topology.numUE   = cfg.scenario.numUE;

    % 基站位置（1 宏 + 3 小区）
    % 单位：meter
    scenario.topology.gNBPos = [
        0,   0,   25;   % Macro
        200, 0,   10;   % Cell 1
       -200, 0,   10;   % Cell 2
        0,  200,  10;   % Cell 3
    ];

    % UE 初始位置（随机）
    rng(1);
    scenario.topology.ueInitPos = [
        300 * (rand(cfg.scenario.numUE,2) - 0.5), ...
        1.5 * ones(cfg.scenario.numUE,1)
    ];

    %% ===============================
    % 3. UE 移动模型
    %% ===============================
    
    scenario.mobility.model = UEMobilityModel( ...
        'numUE', cfg.scenario.numUE, ...
        'initPos', scenario.topology.ueInitPos, ...
        'areaX', [-400 400], ...
        'areaY', [-400 400], ...
        'speedRange', [1 25], ...
        'highSpeedRatio', 0.3, ...
        'pauseTime', 0 ...
    );


    %% ===============================
    % 4. 业务模型
    %% ===============================
    scenario.traffic.model = TrafficModel( ...
    'numUE', cfg.scenario.numUE, ...
    'slotDuration', cfg.sim.slotDuration ...
    );
    
    %% ===============================
    % 5. 信道模型配置
    %% ===============================
    scenario.channel.type = 'CDL';

    scenario.channel.cdl = struct();
    scenario.channel.cdl.DelayProfile = 'CDL-D';
    scenario.channel.cdl.DelaySpread  = 300e-9;
    scenario.channel.cdl.CarrierFreq  = 3.5e9;
    scenario.channel.cdl.MaxDoppler   = 30;

    %% ===============================
    % 6. 基线无线参数
    %% ===============================
    scenario.radio.txPower.cell = 40;     % dBm
    scenario.radio.txPower.ue   = 23;     % dBm

    scenario.radio.bandwidth = 20e6;
    scenario.radio.scs       = 30e3;

    %% ===============================
    % 7. 能耗模型参数
    %% ===============================
    scenario.energy.P0 = 200;   % W
    scenario.energy.k  = 4;

    fprintf('[ScenarioBuilder] Scenario ready\n');

end
