classdef RanContext
%RANCONTEXT Unified runtime state container for modular NR kernel
%
% All models read/write ctx.
% Kernel only orchestrates pipeline.
%
% Persistent fields:
%   - UE / cell state
%   - KPI accumulators
%   - HO states
%
% Per-slot fields stored in ctx.tmp
%

    properties
        %% =========================================================
        % Global / Static references
        %% =========================================================
        cfg
        scenario

        %% =========================================================
        % Time
        %% =========================================================
        slot
        dt

        %% =========================================================
        % UE state
        %% =========================================================
        uePos               % [numUE x 3]
        servingCell         % [numUE x 1]
        rsrp_dBm            % [numUE x numCell]
        sinr_dB             % [numUE x 1]

        %% =========================================================
        % HO state
        %% =========================================================
        hoTimer                     % [numUE x 1]
        ueBlockedUntilSlot          % interruption end slot
        uePostHoUntilSlot           % post-HO penalty window end
        uePostHoSinrPenalty_dB      % current penalty value

        %% =========================================================
        % Scheduler state
        %% =========================================================
        rrPtr                       % per-cell round-robin pointer

        %% =========================================================
        % Radio / cell parameters
        %% =========================================================
        numPRB
        txPowerCell_dBm
        bandwidthHz

        %% =========================================================
        % Energy parameters
        %% =========================================================
        P0_W
        k_pa

        %% =========================================================
        % KPI accumulators (persistent)
        %% =========================================================
        accThroughputBitPerUE
        accPRBUsedPerCell
        accPRBTotalPerCell
        accHOCount
        accDroppedTotal
        accDroppedURLLC
        accEnergyJPerCell

        %% =========================================================
        % Control
        %% =========================================================
        action

        %% =========================================================
        % Per-slot temporary data
        %% =========================================================
        tmp
    end

    methods

        %% =========================================================
        % Constructor
        %% =========================================================
        function obj = RanContext()
            obj.tmp = struct();
        end

        %% =========================================================
        % Clear per-slot temporary data
        %% =========================================================
        function obj = clearSlotTemp(obj)

            % Reset temp container
            obj.tmp = struct();

            % PHY feedback buffers
            obj.tmp.lastCQIPerUE  = zeros(obj.cfg.scenario.numUE,1);
            obj.tmp.lastMCSPerUE  = zeros(obj.cfg.scenario.numUE,1);
            obj.tmp.lastBLERPerUE = zeros(obj.cfg.scenario.numUE,1);

            obj.tmp.lastPRBUsedPerCell = ...
                zeros(obj.cfg.scenario.numCell,1);

            % Scheduler output placeholders
            obj.tmp.scheduledUE = ...
                cell(obj.cfg.scenario.numCell,1);

            obj.tmp.prbAlloc = ...
                cell(obj.cfg.scenario.numCell,1);

            % Event container
            obj.tmp.events = struct();
            obj.tmp.events.hoOccured  = false;
            obj.tmp.events.lastHOue   = 0;
            obj.tmp.events.lastHOfrom = 0;
            obj.tmp.events.lastHOto   = 0;

        end
    end
end
