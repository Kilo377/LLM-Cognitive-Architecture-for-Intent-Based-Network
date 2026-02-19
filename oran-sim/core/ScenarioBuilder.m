function scenario = ScenarioBuilder(cfg)

fprintf('[ScenarioBuilder] Build scenario\n');

rng(cfg.sim.randomSeed);   % 可复现

%% ===============================
% 1. Basic simulation
%% ===============================
scenario.sim.slotDuration = cfg.sim.slotDuration;
scenario.sim.numSlot      = cfg.sim.slotPerEpisode;

%% ===============================
% 2. Topology
%% ===============================
numCell = cfg.scenario.numCell;
numUE   = cfg.scenario.numUE;

scenario.topology.numCell = numCell;
scenario.topology.numUE   = numUE;

% ---- gNB layout: 1 center + others in circle ----

gNBPos = zeros(numCell,3);

if numCell == 1
    gNBPos(1,:) = [0 0 25];
else
    % Cell 1 at center (macro)
    gNBPos(1,:) = [0 0 25];

    % Others around circle
    radius = 250;

    angles = linspace(0, 2*pi, numCell); 
    angles(end) = [];   % remove duplicate 2π

    for c = 2:numCell
        gNBPos(c,1) = radius * cos(angles(c-1));
        gNBPos(c,2) = radius * sin(angles(c-1));
        gNBPos(c,3) = 10;
    end
end

scenario.topology.gNBPos = gNBPos;

% ---- UE initial positions ----

areaR = 400;

theta = 2*pi*rand(numUE,1);
r     = areaR*sqrt(rand(numUE,1));

x = r .* cos(theta);
y = r .* sin(theta);
z = 1.5 * ones(numUE,1);

scenario.topology.ueInitPos = [x y z];

%% ===============================
% 3. Mobility
%% ===============================

scenario.mobility.model = UEMobilityModel( ...
    'numUE', numUE, ...
    'initPos', scenario.topology.ueInitPos, ...
    'areaX', [-areaR areaR], ...
    'areaY', [-areaR areaR], ...
    'speedRange', [1 25], ...
    'highSpeedRatio', 0.3, ...
    'pauseTime', 0 );

%% ===============================
% 4. Traffic
%% ===============================

scenario.traffic.model = TrafficModel( ...
    'numUE', numUE, ...
    'slotDuration', cfg.sim.slotDuration );

%% ===============================
% 5. Channel
%% ===============================

scenario.channel.type = 'CDL';

scenario.channel.cdl.DelayProfile = 'CDL-D';
scenario.channel.cdl.DelaySpread  = 300e-9;
scenario.channel.cdl.CarrierFreq  = 3.5e9;
scenario.channel.cdl.MaxDoppler   = 30;

%% ===============================
% 6. Radio baseline
%% ===============================

scenario.radio.txPower.cell = 40;
scenario.radio.txPower.ue   = 23;

scenario.radio.bandwidth = 20e6;
scenario.radio.scs       = 30e3;

%% ===============================
% 7. Energy baseline
%% ===============================

scenario.energy.P0 = 800;
scenario.energy.k  = 4;

fprintf('[ScenarioBuilder] Scenario ready\n');

end
