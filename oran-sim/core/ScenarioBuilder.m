function scenario = ScenarioBuilder(cfg)
%{
Author: Chongyu Bao
File: ScenarioBuilder.m
Description:
Build simulation scenario from cfg.
All baseline radio parameters are read from cfg.
No hard-coded PHY parameters.
%}

fprintf('[ScenarioBuilder] Build scenario\n');

rng(cfg.sim.randomSeed);

%% =====================================================
% 1. Basic Simulation
%% =====================================================
scenario.sim.slotDuration = cfg.sim.slotDuration;
scenario.sim.numSlot      = cfg.sim.slotPerEpisode;

%% =====================================================
% 2. Topology
%% =====================================================
numCell = cfg.scenario.numCell;
numUE   = cfg.scenario.numUE;

scenario.topology.numCell = numCell;
scenario.topology.numUE   = numUE;

gNBPos = zeros(numCell,3);

if numCell == 1
    gNBPos(1,:) = [0 0 25];
else
    gNBPos(1,:) = [0 0 25];

    radius = 250;
    angles = linspace(0,2*pi,numCell);
    angles(end) = [];

    for c = 2:numCell
        gNBPos(c,1) = radius*cos(angles(c-1));
        gNBPos(c,2) = radius*sin(angles(c-1));
        gNBPos(c,3) = 10;
    end
end

scenario.topology.gNBPos = gNBPos;

%% =====================================================
% UE Initial Positions
%% =====================================================
areaR = 400;

theta = 2*pi*rand(numUE,1);
r     = areaR*sqrt(rand(numUE,1));

x = r .* cos(theta);
y = r .* sin(theta);
z = 1.5*ones(numUE,1);

scenario.topology.ueInitPos = [x y z];

%% =====================================================
% 3. Mobility
%% =====================================================
scenario.mobility.model = UEMobilityModel( ...
    'numUE', numUE, ...
    'initPos', scenario.topology.ueInitPos, ...
    'areaX', [-areaR areaR], ...
    'areaY', [-areaR areaR], ...
    'speedRange', [1 25], ...
    'highSpeedRatio', 0.3, ...
    'pauseTime', 0 );

%% =====================================================
% 4. Traffic
%% =====================================================
scenario.traffic.model = TrafficModel( ...
    'numUE', numUE, ...
    'slotDuration', cfg.sim.slotDuration );

%% ---------------- Hotspot reassignment ----------------
if isfield(cfg,'traffic') && ...
   isfield(cfg.traffic,'hotspot') && ...
   cfg.traffic.hotspot.enable

    hotCell = cfg.traffic.hotspot.cellId;

    uePos = scenario.topology.ueInitPos(:,1:2);
    gNB   = scenario.topology.gNBPos(:,1:2);

    servingCell = zeros(numUE,1);

    for u = 1:numUE
        d2 = sum((gNB - uePos(u,:)).^2,2);
        [~, servingCell(u)] = min(d2);
    end

    for u = 1:numUE

        if servingCell(u) == hotCell
            if rand < cfg.traffic.hotspot.heavyRatioInHot
                scenario.traffic.model.trafficClassPerUE(u) = 2;
            else
                scenario.traffic.model.trafficClassPerUE(u) = 1;
            end
        else
            if rand < cfg.traffic.hotspot.heavyRatioOutHot
                scenario.traffic.model.trafficClassPerUE(u) = 2;
            else
                scenario.traffic.model.trafficClassPerUE(u) = 1;
            end
        end
    end
end

%% =====================================================
% 5. Channel
%% =====================================================
scenario.channel.type = 'CDL';

scenario.channel.cdl.DelayProfile = 'CDL-D';
scenario.channel.cdl.DelaySpread  = 300e-9;
scenario.channel.cdl.CarrierFreq  = 3.5e9;
scenario.channel.cdl.MaxDoppler   = 30;

%% =====================================================
% 6. Radio Baseline (READ FROM CFG)
%% =====================================================
scenario.radio.txPower.cell = cfg.radio.txPower_dBm;
scenario.radio.txPower.ue   = 23;

scenario.radio.bandwidth = cfg.radio.bandwidthHz;
scenario.radio.scs       = 30e3;

%% =====================================================
% 7. Energy Baseline
%% =====================================================
scenario.energy.P0 = 800;
scenario.energy.k  = 4;

fprintf('[ScenarioBuilder] Scenario ready\n');

end