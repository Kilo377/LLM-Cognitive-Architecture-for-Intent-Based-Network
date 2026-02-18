classdef ObsAdapter < handle
%OBSADAPTER Standard full-state exposure layer (RIC v2)
%
% Principles:
% - Full mirror of RanStateBus
% - No filtering
% - No transformation
% - Safe default handling

    properties
        cfg
    end

    methods

        function obj = ObsAdapter(cfg)
            obj.cfg = cfg;
        end

        function obs = buildObs(obj, state) %#ok<INUSD>

            obs = struct();

            %% ===== Core mirror =====
            obs.time     = state.time;
            obs.topology = state.topology;
            obs.ue       = state.ue;
            obs.cell     = state.cell;

            % 补充 radio（物理层全局参数）
            if isfield(state,'radio')
                obs.radio = state.radio;
            else
                obs.radio = struct();
            end

            obs.channel  = state.channel;
            obs.events   = state.events;
            obs.kpi      = state.kpi;

            %% ===== RIC Meta =====
            obs.meta = struct();
            obs.meta.slot        = state.time.slot;
            obs.meta.timestamp_s = state.time.t_s;

            %% ===== Optional future extension bucket =====
            % 允许后续追加字段而不破坏接口
            obs.ext = struct();

        end
    end
end
