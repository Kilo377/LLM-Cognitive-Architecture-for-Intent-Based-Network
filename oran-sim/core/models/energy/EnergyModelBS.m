classdef EnergyModelBS
% ENERGYMODELBS v5.2 (Final stable, no isfield misuse)
%
% Control source (PERSISTENT):
%   ctx.ctrl.basePowerScale
%   ctx.ctrl.cellSleepState
%
% Runtime source:
%   ctx.txPowerCell_dBm
%   ctx.numPRBPerCell
%   ctx.tmp.lastPRBUsedPerCell
%
% Writes:
%   ctx.accEnergyJPerCell
%   ctx.tmp.energyWPerCell
%   ctx.tmp.cell.power_W
%
% Rules:
%   - NEVER read ctx.action
%   - NEVER use isfield(ctx,'ctrl')
%   - ctrl is guaranteed by RanContext constructor
%

    properties
        P0_on_W
        P0_scale

        kPA

        kLoad_W
        loadGamma

        E_ho_J
        E_pingpong_J
        E_rlf_J

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
            obj.E_rlf_J      = 5.0;

            obj.applyToBase = true;
            obj.applyToPA   = true;
        end


        function ctx = step(obj, ctx)

            numCell = ctx.cfg.scenario.numCell;

            %% =====================================================
            % 0) Init accumulators + tmp outputs
            %% =====================================================
            if isempty(ctx.accEnergyJPerCell)
                ctx.accEnergyJPerCell = zeros(numCell,1);
            end

            if isempty(ctx.tmp)
                ctx.tmp = struct();
            end
            if ~isfield(ctx.tmp,'cell')
                ctx.tmp.cell = struct();
            end

            ctx.tmp.energyWPerCell = zeros(numCell,1);
            ctx.tmp.cell.power_W   = zeros(numCell,1);

            %% =====================================================
            % 1) Load ratio (PRB utilization)
            %% =====================================================
            load = zeros(numCell,1);

            if isfield(ctx.tmp,'lastPRBUsedPerCell')

                used = ctx.tmp.lastPRBUsedPerCell(:);

                if numel(used) == numCell

                    total = ctx.numPRBPerCell(:);
                    total(total<=0) = 1;

                    load = used ./ total;
                end
            end

            load = min(max(load,0),1);

            %% =====================================================
            % 2) Sleep scaling (direct read from ctrl)
            %% =====================================================
            ss = ctx.ctrl.cellSleepState(:);
            ss = round(ss);
            ss = min(max(ss,0),2);

            idx = ss + 1;
            sleepScale = obj.P0_scale(idx).';

            %% =====================================================
            % 3) Energy scale (direct read from ctrl)
            %% =====================================================
            energyScale = ctx.ctrl.basePowerScale(:);
            energyScale = max(energyScale,0.1);

            % Debug (first 3 slots)
            %if ctx.slot <= 3
            %    disp("EnergyModel effective energyScale:");
            %    disp(energyScale.');
            %end

            %% =====================================================
            % 4) Tx power (per-cell)
            %% =====================================================
            txPower_dBm = ctx.txPowerCell_dBm(:);
            txPower_dBm = min(max(txPower_dBm,-100),80);

            Ptx_W = 10.^((txPower_dBm - 30)/10);

            %% =====================================================
            % 5) Compute power components
            %% =====================================================
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

            % Load dependent (not scaled)
            Pld = obj.kLoad_W * (load.^obj.loadGamma);

            % Total
            P = P0 + Ppa + Pld;

            P(~isfinite(P)) = 0;
            P = max(P,0);

            %% =====================================================
            % 6) Integrate energy
            %% =====================================================
            ctx.accEnergyJPerCell = ctx.accEnergyJPerCell + P * ctx.dt;

            ctx.tmp.energyWPerCell = P;
            ctx.tmp.cell.power_W   = P;

            %% =====================================================
            % 7) Event-driven signaling energy
            %% =====================================================
            if isfield(ctx.tmp,'events')

                ev = ctx.tmp.events;

                % HO
                if isfield(ev,'hoOccured') && ev.hoOccured

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

                % PingPong
                if isfield(ev,'pingPongCountInc') && ev.pingPongCountInc>0
                    extra = obj.E_pingpong_J * ev.pingPongCountInc / numCell;
                    ctx.accEnergyJPerCell = ctx.accEnergyJPerCell + extra;
                end

                % RLF
                if isfield(ev,'rlfOccured') && ev.rlfOccured

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


