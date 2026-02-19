function cfg = default_config()

% ==============================
% SIMULATION
% ==============================
cfg.sim.slotDuration     = 10 * 1e-3;     % 1ms
cfg.sim.slotPerEpisode   = 200;      % episode length
cfg.sim.randomSeed       = 2026;     % reproducible

% Debug
cfg.debug = struct();
cfg.debug.enable  = true;      % 是否开启debug
cfg.debug.every   = 100;       % 每100个slot打印一次
cfg.debug.modules = "all";     % 也可以指定 "radio","handover" 等
cfg.debug.level   = 1;         % 详细等级


% ==============================
% SCENARIO
% ==============================
cfg.scenario.numCell = 4;
cfg.scenario.numUE   = 40;

% ==============================
% RADIO BASELINE
% ==============================
cfg.radio.txPower_dBm = 40;
cfg.radio.bandwidthHz = 20e6;

% ==============================
% SENSITIVITY DEFAULT SWEEP
% ==============================
cfg.sweep.txPowerOffset_dB = [-10 0 10];
cfg.sweep.bandwidthScale   = [0.5 1 1.5];
cfg.sweep.sleepState       = [0 1 2];

end
