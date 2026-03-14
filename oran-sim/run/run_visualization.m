%{
Author: Chongyu Bao (zt25108@bristol.ac.uk)

File: run_visualize_ue.m

Description:
Standalone visualization runner.
This script loads default_config,
builds scenario,
runs mobility only,
computes nearest-cell association,
and visualizes UE distribution.
%}

clear; clc;

%% =========================================================
% 1. Load config
%% =========================================================
cfg = default_config();

%% =========================================================
% 2. Build scenario
%% =========================================================
scenario = ScenarioBuilder(cfg);

numCell = scenario.topology.numCell;
numUE   = scenario.topology.numUE;
gNBPos  = scenario.topology.gNBPos;

mobility = scenario.mobility.model;

slotDuration = scenario.sim.slotDuration;
numSlot      = scenario.sim.numSlot;

%% =========================================================
% 3. Visualization
%% =========================================================
viz = VisualizationManager();

%% =========================================================
% 4. Simulation loop (mobility only)
%% =========================================================
for slot = 1:numSlot

    % ---- mobility update ----
    [mobility, pos] = mobility.step(slotDuration);

    % ---- compute serving cell (nearest gNB) ----
    servingCell = zeros(numUE,1);

    for u = 1:numUE
        d2 = sum((gNBPos(:,1:2) - pos(u,:)).^2,2);
        [~, servingCell(u)] = min(d2);
    end

    % ---- fake SINR (distance-based, just for visualization) ----
    sinr_dB = zeros(numUE,1);

    for u = 1:numUE
        c = servingCell(u);
        d = norm(pos(u,:) - gNBPos(c,1:2));
        sinr_dB(u) = 30 - 0.05*d;   % simple decay model
    end

    % ---- build state struct ----
    state = struct();

    state.topology.gNBPos = gNBPos(:,1:2);

    state.ue.pos = pos;
    state.ue.servingCell = servingCell;
    state.ue.speed = mobility.speed;
    state.ue.sinr_dB = sinr_dB;

    state.time.t_s = slot * slotDuration;

    % ---- fake KPI (only for panel display) ----
    state.kpi.prbUtilPerCell = histcounts(servingCell,1:(numCell+1))'/numUE;
    state.kpi.throughputBitPerUE = ones(numUE,1)*1e6;
    state.kpi.dropURLLC = 0;

    % ---- update visualization ----
    viz.update(state);

end