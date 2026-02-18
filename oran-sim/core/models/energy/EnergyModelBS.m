classdef EnergyModelBS
%ENERGYMODELBS v2 Base-station energy model with policy knobs
%
% Reads:
%   ctx.dt
%   ctx.numPRB
%   ctx.tmp.lastPRBUsedPerCell
%   ctx.action.sleep.cellSleepState
%   ctx.action.power.cellTxPowerOffset_dB
%   ctx.action.energy.basePowerScale
%   ctx.tmp.events (optional)
%
% Writes:
%   ctx.accEnergyJPerCell
%   ctx.tmp.energyWPerCell

    properties
        % Base power (W) per cell when ON
        P0_on_W

        % Sleep scaling for base power
        % sleepState: 0:on, 1:light, 2:deep
        P0_scale

        % PA term multiplier
        kPA

        % Load-dependent term
        kLoad_W
        loadGamma

        % Event-driven signaling energy (J)
        E_ho_J
        E_pingpong_J
        E_rlf_J

        % How energy.basePowerScale affects consumption
        % applyToBase: base circuit power scaling
        % applyToPA  : PA power scaling
        applyToBase
        applyToPA
    end

    methods
        function obj = EnergyModelBS()
            obj.P0_on_W   = 800;
            obj.P0_scale  = [1.0 0.55 0.25];

            obj.kPA       = 4.0;

            obj.kLoad_W   = 120;
            obj.loadGamma = 1.2;

            obj.E_ho_J       = 2.0;
            obj.E_pingpong_J = 1.0;
            obj.E_rlf_J       = 5.0;

            obj.applyToBase = true;
            obj.applyToPA   = true;
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

            %% 1) Load ratio (0..1)
            load = zeros(numCell,1);
            if isfield(ctx.tmp,'lastPRBUsedPerCell') && ctx.numPRB > 0
                load = ctx.tmp.lastPRBUsedPerCell(:) ./ ctx.numPRB;
                load = min(max(load,0),1);
            end

            %% 2) Sleep scale
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

            %% 3) energy.basePowerScale (0.2..1.2 in validate)
            energyScale = ones(numCell,1);
            if ~isempty(ctx.action) && isfield(ctx.action,'energy') && ...
                    isfield(ctx.action.energy,'basePowerScale')
                s = ctx.action.energy.basePowerScale;
                if isnumeric(s) && numel(s)==numCell
                    energyScale = s(:);
                end
            end

            %% 4) Tx power for PA energy
            % Base Tx power per cell (dBm)
            txPower_dBm = ctx.txPowerCell_dBm * ones(numCell,1);

            % If you want ActionApplier to provide a base override, honor it
            if isfield(ctx.tmp,'txPowerBase_dBm')
                tp = ctx.tmp.txPowerBase_dBm;
                if isnumeric(tp) && numel(tp)==numCell
                    txPower_dBm = tp(:);
                end
            end

            % Add power offset
            if ~isempty(ctx.action) && isfield(ctx.action,'power') && ...
                    isfield(ctx.action.power,'cellTxPowerOffset_dB')
                off = ctx.action.power.cellTxPowerOffset_dB;
                if isnumeric(off) && numel(off)==numCell
                    txPower_dBm = txPower_dBm + off(:);
                end
            end

            %% 5) Convert to Watt
            Ptx_W = 10.^((txPower_dBm - 30)/10);

            %% 6) Compute components
            P0 = obj.P0_on_W * sleepScale;
            if obj.applyToBase
                P0 = P0 .* energyScale;
            end

            Ppa = obj.kPA * Ptx_W;
            if obj.applyToPA
                Ppa = Ppa .* energyScale;
            end

            Pld = obj.kLoad_W * (load .^ obj.loadGamma);

            P = P0 + Ppa + Pld;

            %% 7) Integrate
            ctx.accEnergyJPerCell = ctx.accEnergyJPerCell + P * ctx.dt;
            ctx.tmp.energyWPerCell = P;

            %% 8) Event-driven signaling energy
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
