classdef EnergyModelBS
%ENERGYMODELBS Base-station energy model (system-level, realistic)
%
% Reads:
%   ctx.txPowerCell_dBm
%   ctx.tmp.lastPRBUsedPerCell
%   ctx.numPRB
%   ctx.dt
%   ctx.action.sleep.cellSleepState   (optional)
%   ctx.tmp.events.hoOccured / pingPongCountInc / rlfOccured (optional)
%
% Writes:
%   ctx.accEnergyJPerCell
%   ctx.tmp.energyWPerCell (optional for observability)

    properties
        % Base power (W) per cell when ON (dominant)
        P0_on_W

        % Sleep scaling for base power
        % sleepState: 0:on, 1:light, 2:deep
        P0_scale

        % PA term
        kPA

        % Load-dependent term
        kLoad_W
        loadGamma

        % HO/RLF signaling energy (J per event)
        E_ho_J
        E_pingpong_J
        E_rlf_J
    end

    methods
        function obj = EnergyModelBS()
            % These defaults are "macro-ish". You can tune per scenario.
            obj.P0_on_W   = 800;                 % dominant base power
            obj.P0_scale  = [1.0 0.55 0.25];      % light/deep sleep saves energy
            obj.kPA       = 4.0;                 % PA multiplier on Ptx_W

            obj.kLoad_W   = 120;                 % small load term
            obj.loadGamma = 1.2;                 % mild nonlinearity

            obj.E_ho_J       = 2.0;              % HO signaling energy
            obj.E_pingpong_J = 1.0;              % extra if ping-pong
            obj.E_rlf_J       = 5.0;              % RLF recovery cost
        end

        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;

            if ~isfield(ctx,'accEnergyJPerCell') || isempty(ctx.accEnergyJPerCell)
                ctx.accEnergyJPerCell = zeros(numCell,1);
            end
            if ~isfield(ctx,'tmp') || isempty(ctx.tmp)
                ctx.tmp = struct();
            end
            ctx.tmp.energyWPerCell = zeros(numCell,1);

            %% 1) load ratio (0..1)
            load = zeros(numCell,1);
            if isfield(ctx.tmp,'lastPRBUsedPerCell') && ctx.numPRB > 0
                load = ctx.tmp.lastPRBUsedPerCell(:) ./ ctx.numPRB;
                load = min(max(load,0),1);
            end

            %% 2) sleep state
            sleepScale = ones(numCell,1);
            if ~isempty(ctx.action) && isfield(ctx.action,'sleep') && ...
                    isfield(ctx.action.sleep,'cellSleepState')
                ss = ctx.action.sleep.cellSleepState;
                if isnumeric(ss) && numel(ss)==numCell
                    for c = 1:numCell
                        idx = min(max(round(ss(c))+1,1),3);
                        sleepScale(c) = obj.P0_scale(idx);
                    end
                end
            end

            %% 3) Tx power -> Ptx_W
            txPower_dBm = ctx.txPowerCell_dBm * ones(numCell,1);
            if ~isempty(ctx.action) && isfield(ctx.action,'power') && ...
                    isfield(ctx.action.power,'cellTxPowerOffset_dB')
                off = ctx.action.power.cellTxPowerOffset_dB;
                if isnumeric(off) && numel(off)==numCell
                    txPower_dBm = txPower_dBm + off(:);
                end
            end
            Ptx_W = 10.^((txPower_dBm - 30)/10);

            %% 4) Compute power per cell
            P0 = obj.P0_on_W * sleepScale;
            Ppa = obj.kPA * Ptx_W;
            Pld = obj.kLoad_W * (load .^ obj.loadGamma);

            P = P0 + Ppa + Pld;

            %% 5) Integrate energy
            ctx.accEnergyJPerCell = ctx.accEnergyJPerCell + P * ctx.dt;
            ctx.tmp.energyWPerCell = P;

            %% 6) Event-driven signaling energy
            % HO events are UE-level. We charge fromCell and toCell equally if known.
            if isfield(ctx.tmp,'events') && ~isempty(ctx.tmp.events)

                ev = ctx.tmp.events;

                if isfield(ev,'hoOccured') && ev.hoOccured && ...
                   isfield(ev,'lastHOfrom') && isfield(ev,'lastHOto')

                    fromC = ev.lastHOfrom;
                    toC   = ev.lastHOto;

                    if fromC>=1 && fromC<=numCell
                        ctx.accEnergyJPerCell(fromC) = ctx.accEnergyJPerCell(fromC) + 0.5*obj.E_ho_J;
                    end
                    if toC>=1 && toC<=numCell
                        ctx.accEnergyJPerCell(toC)   = ctx.accEnergyJPerCell(toC)   + 0.5*obj.E_ho_J;
                    end
                end

                if isfield(ev,'pingPongCountInc') && ev.pingPongCountInc > 0
                    % spread cost across all cells (simple)
                    ctx.accEnergyJPerCell = ctx.accEnergyJPerCell + ...
                        (obj.E_pingpong_J * ev.pingPongCountInc / numCell) * ones(numCell,1);
                end

                if isfield(ev,'rlfOccured') && ev.rlfOccured && ...
                   isfield(ev,'rlfFrom') && isfield(ev,'rlfTo')
                    fromC = ev.rlfFrom;
                    toC   = ev.rlfTo;

                    if fromC>=1 && fromC<=numCell
                        ctx.accEnergyJPerCell(fromC) = ctx.accEnergyJPerCell(fromC) + 0.5*obj.E_rlf_J;
                    end
                    if toC>=1 && toC<=numCell
                        ctx.accEnergyJPerCell(toC)   = ctx.accEnergyJPerCell(toC)   + 0.5*obj.E_rlf_J;
                    end
                end
            end
        end
    end
end
