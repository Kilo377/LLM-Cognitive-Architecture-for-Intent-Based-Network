function cfg = default_config()

% ==============================
% SIMULATION
% ==============================
cfg.sim.slotDuration     = 1e-3;     % 1ms
cfg.sim.slotPerEpisode   = 1000;     % episode length
cfg.sim.randomSeed       = 2026;     % reproducible

% Debug
cfg.debug = struct();
cfg.debug.enable  = true;      % 是否开启debug
cfg.debug.every   = 200;       % 每200个slot打印一次
cfg.debug.modules = ["all"];     % 也可以指定 "radio","handover" "all"等
cfg.debug.level   = 2;         % 详细等级1


% ==============================
% SCENARIO
% ==============================
cfg.scenario.numCell = 4;
cfg.scenario.numUE   = 40;

% ==============================
% CONTROL
% ==============================
cfg.ctrl = struct();
cfg.ctrl.selectedUEPolicy = "none";

% ==============================
% RADIO BASELINE
% ==============================
cfg.radio.txPower_dBm = 18;  
cfg.radio.bandwidthHz = 20e6;

% ==============================
% TRAFFIC
% ==============================
cfg.traffic = struct();

% 轻度拥塞控制
cfg.traffic.overloadFactor = 1.25;

% UE traffic class 比例
cfg.traffic.silentRatio = 0.15;
cfg.traffic.heavyRatio  = 0.20;

% heavy 用户倍率
cfg.traffic.heavyMultiplierE = 6.0;
cfg.traffic.heavyMultiplierU = 2.5;
cfg.traffic.heavyMultiplierM = 3.0;

% silent 用户倍率
cfg.traffic.silentMultiplier = 0.10;

% ==============================
% TRAFFIC HOTSPOT
% ==============================
cfg.traffic.hotspot.enable = true;
cfg.traffic.hotspot.cellId = 1;        % 哪个小区是热点
cfg.traffic.hotspot.heavyRatioInHot = 0.6;  % 热点小区 heavy 比例
cfg.traffic.hotspot.heavyRatioOutHot = 0.05; % 其他小区 heavy 比例

% 是否启用 burst
cfg.traffic.enableBurst = true;


% ==============================
% DYNAMIC ENVIRONMENT
% ==============================
cfg.dynamic = struct();
cfg.dynamic.enable = true;
cfg.dynamic.profiles = ["traffic","mobility","radio"];
cfg.dynamic.periodRange = [300 500];
cfg.dynamic.intensity = "medium";
cfg.dynamic.seed = 2026;

% ==============================
% TREND (LONG-TERM DRIFT)
% ==============================
cfg.trend = struct();
cfg.trend.enable = true;
cfg.trend.startSlot = 300;
cfg.trend.endSlot = 1600;
cfg.trend.loadRange = [1.0 2.2];
cfg.trend.heavyMulRange = [1.0 1.8];
cfg.trend.activeUERange = [0.3 1.0];
cfg.trend.edgeBiasRange = [0.0 1.0];
cfg.trend.burstOnScaleRange = [1.0 1.6];
cfg.trend.burstOffScaleRange = [1.0 0.6];



% ==============================
% SENSITIVITY DEFAULT SWEEP
% ==============================
%cfg.sweep.txPowerOffset_dB = [-10 0 10];
%cfg.sweep.bandwidthScale   = [0.5 1 1.5];
%cfg.sweep.sleepState       = [0 1 2];

% ==============================
% NON-RT RIC
% ==============================
cfg.nonRT.periodSlot = 50;
cfg.nonRT.triggerTime_s = 0.4 * 1.0;
cfg.nonRT.reportPath = "oran-sim/bus_A1/non_rt_report.json";
cfg.nonRT.policyPath = "oran-sim/bus_A1/non_rt_policy.json";
cfg.nonRT.policiesPath = "oran-sim/bus_A1/existing_policys.json";
cfg.nonRT.timeout_s  = 120;
cfg.nonRT.waitInterval_s = 0.5;
cfg.nonRT.smoCommand = "/opt/anaconda3/bin/python -B /Users/kilobao/Documents/MATLAB/Examples/R2025b/5g/5GORAN/oran-sim/smo/smo.py";

end
