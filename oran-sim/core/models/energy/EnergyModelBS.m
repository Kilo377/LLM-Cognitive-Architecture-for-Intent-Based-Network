classdef EnergyModelBS
% ENERGYMODELBS v3
%
% Policy-aware base station energy model
%
% Reads:
%   ctx.dt
%   ctx.numPRB
%   ctx.tmp.cell.prbUsed
%   ctx.tmp.lastPRBUsedPerCell
%   ctx.tmp.basePowerScale
%   ctx.action.sleep.cellSleepState
%   ctx.action.power.cellTxPowerOffset_dB
%
% Writes:
%   ctx.accEnergyJPerCell
%   ctx.tmp.energyWPerCell
%   ctx.tmp.cell.power_W

    properties
        % Base power when ON
        P0_on_W

        % Sleep scaling
        P0_scale

        % PA multiplier
        kPA

        % Load dependent term
        kLoad_W
        loadGamma

        % Event signaling energy
        E_ho_J
        E_pingpong_J
        E_rlf_J

        % Control flags
        applyToBase
        applyToPA
    end

    methods

        function obj = EnergyModelBS()

            obj.P0_on_W  = 800;
            obj.P0_scale = [1.0 0.55 0.25];

            obj.kPA      = 4.0;

            obj.kLoad_W  = 120;
            obj.loadGamma = 1.2;

            obj.E_ho_J       = 2.0;
            obj.E_pingpong_J = 1.0;
            obj.E_rlf_J      = 5.0;

            obj.applyToBase = true;
            obj.applyToPA   = true;
        end

        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;

            if isempty(ctx.accEnergyJPerCell)
                ctx.accEnergyJPerCell = zeros(numCell,1);
            end

            ctx.tmp.energyWPerCell = zeros(numCell,1);

            if ~isfield(ctx.tmp,'cell')
                ctx.tmp.cell = struct();
            end
            ctx.tmp.cell.power_W = zeros(numCell,1);

            %% -------------------------------------------------
            % 1) Load ratio
            %% -------------------------------------------------
            load = zeros(numCell,1);

            if isfield(ctx.tmp,'cell') && isfield(ctx.tmp.cell,'prbUsed') ...
                    && ctx.numPRB > 0
                load = ctx.tmp.cell.prbUsed(:) ./ ctx.numPRB;
            elseif isfield(ctx.tmp,'lastPRBUsedPerCell') && ctx.numPRB > 0
                load = ctx.tmp.lastPRBUsedPerCell(:) ./ ctx.numPRB;
            end

            load = min(max(load,0),1);

            %% -------------------------------------------------
            % 2) Sleep scale
            %% -------------------------------------------------
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

            %% -------------------------------------------------
            % 3) energy.basePowerScale
            %% -------------------------------------------------
            energyScale = ones(numCell,1);

            if isfield(ctx.tmp,'basePowerScale')
                s = ctx.tmp.basePowerScale;
                if isnumeric(s) && numel(s)==numCell
                    energyScale = s(:);
                end
            end

            %% -------------------------------------------------
            % 4) Tx Power
            %% -------------------------------------------------
            if isscalar(ctx.txPowerCell_dBm)
                txPower_dBm = ctx.txPowerCell_dBm * ones(numCell,1);
            else
                txPower_dBm = ctx.txPowerCell_dBm(:);
            end


            if ~isempty(ctx.action) && isfield(ctx.action,'power') && ...
                    isfield(ctx.action.power,'cellTxPowerOffset_dB')

                off = ctx.action.power.cellTxPowerOffset_dB;
                if isnumeric(off) && numel(off)==numCell
                    txPower_dBm = txPower_dBm + off(:);
                end
            end

            Ptx_W = 10.^((txPower_dBm - 30)/10);

            %% -------------------------------------------------
            % 5) Compute components
            %% -------------------------------------------------
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

            %% -------------------------------------------------
            % 6) Integrate energy
            %% -------------------------------------------------
            ctx.accEnergyJPerCell = ctx.accEnergyJPerCell + P * ctx.dt;

            ctx.tmp.energyWPerCell = P;
            ctx.tmp.cell.power_W   = P;

            %% -------------------------------------------------
            % 7) Event-driven signaling energy
            %% -------------------------------------------------
            if isfield(ctx.tmp,'events') && ~isempty(ctx.tmp.events)

                ev = ctx.tmp.events;

                if isfield(ev,'hoOccured') && ev.hoOccured && ...
                   isfield(ev,'lastHOfrom') && isfield(ev,'lastHOto')

                    fromC = ev.lastHOfrom;
                    toC   = ev.lastHOto;

                    if fromC>=1 && fromC<=numCell
                        ctx.accEnergyJPerCell(fromC) = ...
                            ctx.accEnergyJPerCell(fromC) + 0.5*obj.E_ho_J;
                    end

                    if toC>=1 && toC<=numCell
                        ctx.accEnergyJPerCell(toC) = ...
                            ctx.accEnergyJPerCell(toC) + 0.5*obj.E_ho_J;
                    end
                end

                if isfield(ev,'pingPongCountInc') && ev.pingPongCountInc > 0
                    ctx.accEnergyJPerCell = ctx.accEnergyJPerCell + ...
                        (obj.E_pingpong_J * ev.pingPongCountInc / numCell) ...
                        * ones(numCell,1);
                end

                if isfield(ev,'rlfOccured') && ev.rlfOccured && ...
                   isfield(ev,'rlfFrom') && isfield(ev,'rlfTo')

                    fromC = ev.rlfFrom;
                    toC   = ev.rlfTo;

                    if fromC>=1 && fromC<=numCell
                        ctx.accEnergyJPerCell(fromC) = ...
                            ctx.accEnergyJPerCell(fromC) + 0.5*obj.E_rlf_J;
                    end

                    if toC>=1 && toC<=numCell
                        ctx.accEnergyJPerCell(toC) = ...
                            ctx.accEnergyJPerCell(toC) + 0.5*obj.E_rlf_J;
                    end
                end
            end
        end
    end
end
