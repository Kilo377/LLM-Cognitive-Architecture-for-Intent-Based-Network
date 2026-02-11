classdef ObsAdapter
%OBSADAPTER Build xApp observation from RanStateBus (MVP)

    properties
        cfg
    end

    methods
        function obj = ObsAdapter(cfg)
            obj.cfg = cfg;
        end

        function obs = buildObs(obj, state) %#ok<INUSD>
            obs = struct();

            obs.time_s = state.time.t_s;

            obs.numUE   = state.topology.numUE;
            obs.numCell = state.topology.numCell;

            obs.servingCell = state.ue.servingCell;
            obs.sinr_dB      = state.ue.sinr_dB;

            obs.buffer_bits  = state.ue.buffer_bits;
   
            obs.urgent_pkts  = state.ue.urgent_pkts;

            obs.minDeadline_slot = state.ue.minDeadline_slot; % 新增
            % 预留：后面调度/功控/波束会用
            obs.cqi = state.ue.cqi;
        end
    end
end
