classdef EnergyModelBS
% ENERGYMODELBS v6 (Unified debug + robust energy accounting)
%
% Reads:
%   ctx.ctrl.basePowerScale
%   ctx.ctrl.cellSleepState
%   ctx.txPowerCell_dBm
%   ctx.numPRBPerCell
%   ctx.tmp.lastPRBUsedPerCell
%   ctx.tmp.events (optional)
%
% Writes:
%   ctx.accEnergyJPerCell
%   ctx.tmp.energyWPerCell
%   ctx.tmp.cell.power_W
%   ctx.tmp.debug.energy
%
% Debug:
%   obj = obj.setDebug(enable, firstSlots)

    properties
        % Static power
        P0_on_W
        P0_scale

        % Power amplifier
        kPA

        % Load dependent
        kLoad_W
        loadGamma

        % Event signaling
        E_ho_J
        E_pingpong_J
        E_rlf_J

        % Scaling control
        applyToBase
        applyToPA

        % Debug
        debugEnable
        debugFirstSlots
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
            obj.E_rlf_J      = 5.0;

            obj.applyToBase = true;
            obj.applyToPA   = true;

            obj.debugEnable     = false;
            obj.debugFirstSlots = 3;
        end

        function obj = setDebug(obj, enable, firstSlots)
            if nargin < 2, enable = true; end
            if nargin < 3, firstSlots = obj.debugFirstSlots; end
            obj.debugEnable = logical(enable);
            obj.debugFirstSlots = max(0, round(firstSlots));
        end


        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;

            %---------------------------------------
            % 0) Init accumulators
            %---------------------------------------
            if isempty(ctx.accEnergyJPerCell)
                ctx.accEnergyJPerCell = zeros(numCell,1);
            end

            if ~isfield(ctx.tmp,'cell')
                ctx.tmp.cell = struct();
            end

            ctx.tmp.energyWPerCell = zeros(numCell,1);
            ctx.tmp.cell.power_W   = zeros(numCell,1);

            %---------------------------------------
            % 1) Load ratio
            %---------------------------------------
            load = zeros(numCell,1);

            if isfield(ctx.tmp,'lastPRBUsedPerCell')
                used = ctx.tmp.lastPRBUsedPerCell(:);
                total = ctx.numPRBPerCell(:);
                total(total<=0) = 1;
                load = used ./ total;
            end

            load = min(max(load,0),1);

            %---------------------------------------
            % 2) Sleep state
            %---------------------------------------
            ss = round(ctx.ctrl.cellSleepState(:));
            ss = min(max(ss,0),2);

            sleepScale = obj.P0_scale(ss+1).';

            %---------------------------------------
            % 3) Energy scale
            %---------------------------------------
            energyScale = max(ctx.ctrl.basePowerScale(:),0.1);

            %---------------------------------------
            % 4) Tx power
            %---------------------------------------
            txPower_dBm = min(max(ctx.txPowerCell_dBm(:),-100),80);
            Ptx_W = 10.^((txPower_dBm - 30)/10);

            %---------------------------------------
            % 5) Compute components
            %---------------------------------------
            % Base
            P0 = obj.P0_on_W * sleepScale;
            if obj.applyToBase
                P0 = P0 .* energyScale;
            end

            % PA
            Ppa = obj.kPA * Ptx_W;
            if obj.applyToPA
                Ppa = Ppa .* energyScale;
            end

            % If deep sleep, PA = 0
            Ppa(ss==2) = 0;

            % Load dependent
            Pld = obj.kLoad_W * (load.^obj.loadGamma);

            % Total
            P = P0 + Ppa + Pld;
            P(~isfinite(P)) = 0;
            P = max(P,0);

            %---------------------------------------
            % 6) Integrate
            %---------------------------------------
            ctx.accEnergyJPerCell = ctx.accEnergyJPerCell + P * ctx.dt;

            ctx.tmp.energyWPerCell = P;
            ctx.tmp.cell.power_W   = P;

            %---------------------------------------
            % 7) Event signaling energy
            %---------------------------------------
            if isfield(ctx.tmp,'events')
                ev = ctx.tmp.events;

                % HO
                if isfield(ev,'hoOccured') && ev.hoOccured
                    fromC = ev.lastHOfrom;
                    toC   = ev.lastHOto;
                    ctx = addEventEnergy(ctx, fromC, toC, obj.E_ho_J);
                end

                % PingPong
                if isfield(ev,'pingPongCountInc') && ev.pingPongCountInc>0
                    extra = obj.E_pingpong_J * ev.pingPongCountInc / numCell;
                    ctx.accEnergyJPerCell = ctx.accEnergyJPerCell + extra;
                end

                % RLF
                if isfield(ev,'rlfOccured') && ev.rlfOccured
                    fromC = ev.rlfFrom;
                    toC   = ev.rlfTo;
                    ctx = addEventEnergy(ctx, fromC, toC, obj.E_rlf_J);
                end
            end

            %---------------------------------------
            % 8) Debug
            %---------------------------------------
            if obj.debugEnable && ctx.slot <= obj.debugFirstSlots

                ctx.tmp.debug.energy.slot   = ctx.slot;
                ctx.tmp.debug.energy.P0     = P0;
                ctx.tmp.debug.energy.Ppa    = Ppa;
                ctx.tmp.debug.energy.Pld    = Pld;
                ctx.tmp.debug.energy.Ptotal = P;
                ctx.tmp.debug.energy.load   = load;
                ctx.tmp.debug.energy.sleep  = ss;
                ctx.tmp.debug.energy.scale  = energyScale;

                %disp("Energy debug slot=" + ctx.slot);
                %disp("Ptotal=" + mat2str(P.',3));
            end
        end
    end
end


function ctx = addEventEnergy(ctx, fromC, toC, E)

numCell = numel(ctx.accEnergyJPerCell);

if fromC>=1 && fromC<=numCell
    ctx.accEnergyJPerCell(fromC) = ...
        ctx.accEnergyJPerCell(fromC) + 0.5*E;
end

if toC>=1 && toC<=numCell
    ctx.accEnergyJPerCell(toC) = ...
        ctx.accEnergyJPerCell(toC) + 0.5*E;
end

end
