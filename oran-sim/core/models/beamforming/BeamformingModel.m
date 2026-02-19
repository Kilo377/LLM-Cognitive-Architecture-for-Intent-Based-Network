classdef BeamformingModel
%BEAMFORMINGMODEL v2 (ctrl-first + unified debug + stable semantics)
%
% Reads (preferred):
%   ctx.ctrl.ueBeamId        [numUE x 1]  0 means no control
%   ctx.ctrl.beamMode        string (optional)
%
% Backward-compat (optional fallback):
%   ctx.action.beam.ueBeamId
%
% Writes:
%   ctx.tmp.beamGain_dB      [numUE x numCell]
%   ctx.tmp.debug.beam       (optional)
%
% Debug:
%   obj = obj.setDebug(enable, firstSlots)

    properties
        numBeamPerCell
        beamAzimuth_rad          % [numCell x numBeam]
        mainLobeGain_dB
        sideLobeGain_dB
        beamwidth3dB_deg
        mismatchPenalty_dB
        defaultPolicy            % "best" | "slightly_suboptimal" | "random"
        perCellSeed

        % Debug
        debugEnable
        debugFirstSlots
    end

    methods
        function obj = BeamformingModel(varargin)
            p = inputParser;
            addParameter(p,'numBeamPerCell',8);
            addParameter(p,'mainLobeGain_dB',12);
            addParameter(p,'sideLobeGain_dB',-3);
            addParameter(p,'beamwidth3dB_deg',20);
            addParameter(p,'defaultPolicy',"slightly_suboptimal");
            addParameter(p,'mismatchPenalty_dB',2);
            addParameter(p,'perCellSeed',7);
            parse(p,varargin{:});

            obj.numBeamPerCell     = p.Results.numBeamPerCell;
            obj.mainLobeGain_dB    = p.Results.mainLobeGain_dB;
            obj.sideLobeGain_dB    = p.Results.sideLobeGain_dB;
            obj.beamwidth3dB_deg   = p.Results.beamwidth3dB_deg;
            obj.defaultPolicy      = p.Results.defaultPolicy;
            obj.mismatchPenalty_dB = p.Results.mismatchPenalty_dB;
            obj.perCellSeed        = p.Results.perCellSeed;

            obj.beamAzimuth_rad = [];

            obj.debugEnable     = false;
            obj.debugFirstSlots = 3;
        end

        function obj = setDebug(obj, enable, firstSlots)
            if nargin < 2, enable = true; end
            if nargin < 3, firstSlots = obj.debugFirstSlots; end
            obj.debugEnable     = logical(enable);
            obj.debugFirstSlots = max(0, round(firstSlots));
        end

        function obj = initialize(obj, ctx)
            numCell = ctx.cfg.scenario.numCell;
            nb = obj.numBeamPerCell;

            obj.beamAzimuth_rad = zeros(numCell, nb);

            for c = 1:numCell
                for b = 1:nb
                    obj.beamAzimuth_rad(c,b) = -pi + (2*pi)*(b-1)/nb;
                end
            end
        end

        function [obj, ctx] = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            if isempty(obj.beamAzimuth_rad)
                obj = obj.initialize(ctx);
            end

            % gNB position compatibility
            if isfield(ctx.scenario,'topology') && isfield(ctx.scenario.topology,'gNBPos')
                gNB = ctx.scenario.topology.gNBPos;
            else
                gNB = ctx.scenario.topology.gNBPos_m;
            end

            if ~isfield(ctx,'tmp') || isempty(ctx.tmp)
                ctx.tmp = struct();
            end
            ctx.tmp.beamGain_dB = zeros(numUE, numCell);

            % -----------------------------
            % 1) Control source (ctrl-first)
            % -----------------------------
            ueBeamId = zeros(numUE,1);
            hasControl = false(numUE,1);
            mode = "static";

            if isfield(ctx,'ctrl') && ~isempty(ctx.ctrl)
                if isfield(ctx.ctrl,'ueBeamId')
                    v = ctx.ctrl.ueBeamId;
                    if isnumeric(v) && numel(v)==numUE
                        ueBeamId = round(v(:));
                        ueBeamId(ueBeamId < 0) = 0;
                        hasControl = ueBeamId > 0;
                    end
                end
                if isfield(ctx.ctrl,'beamMode')
                    mode = ctx.ctrl.beamMode;
                end
            end

            % Backward fallback (only when ctrl is not present)
            if ~any(hasControl) && ~isempty(ctx.action) && isfield(ctx.action,'beam') && isfield(ctx.action.beam,'ueBeamId')
                v = ctx.action.beam.ueBeamId;
                if isnumeric(v) && numel(v)==numUE
                    ueBeamId = round(v(:));
                    ueBeamId(ueBeamId < 0) = 0;
                    hasControl = ueBeamId > 0;
                end
            end

            % -----------------------------
            % 2) Compute beam gain
            % -----------------------------
            for u = 1:numUE
                for c = 1:numCell

                    dx = ctx.uePos(u,1) - gNB(c,1);
                    dy = ctx.uePos(u,2) - gNB(c,2);
                    phi = atan2(dy, dx);

                    if hasControl(u)
                        b = mod(ueBeamId(u)-1, obj.numBeamPerCell) + 1;
                        phi_b = obj.beamAzimuth_rad(c,b);
                        gain = obj.patternGain(phi, phi_b);
                    else
                        gain = obj.defaultGain(phi, c);
                    end

                    % optional future mode hooks
                    if mode == "static"
                        % do nothing
                    end

                    ctx.tmp.beamGain_dB(u,c) = gain;
                end
            end

            % -----------------------------
            % 3) Debug
            % -----------------------------
            if obj.debugEnable && ctx.slot <= obj.debugFirstSlots
                if ~isfield(ctx.tmp,'debug') || isempty(ctx.tmp.debug)
                    ctx.tmp.debug = struct();
                end
                ctx.tmp.debug.beam = struct();
                ctx.tmp.debug.beam.slot = ctx.slot;
                ctx.tmp.debug.beam.mode = mode;
                ctx.tmp.debug.beam.hasControlCount = sum(hasControl);
                ctx.tmp.debug.beam.ueBeamId_head = ueBeamId(1:min(10,numUE));
                %disp("Beam debug slot=" + ctx.slot + ", hasCtrl=" + sum(hasControl));
            end
        end
    end

    methods (Access = private)

        function gain = defaultGain(obj, phi, c)
            nb = obj.numBeamPerCell;

            best = -inf;
            for b = 1:nb
                g = obj.patternGain(phi, obj.beamAzimuth_rad(c,b));
                if g > best
                    best = g;
                end
            end

            if obj.defaultPolicy == "best"
                gain = best;
                return;
            end

            if obj.defaultPolicy == "random"
                rng(obj.perCellSeed + c);
                b = randi(nb);
                gain = obj.patternGain(phi, obj.beamAzimuth_rad(c,b));
                gain = gain - obj.mismatchPenalty_dB;
                return;
            end

            gain = best - obj.mismatchPenalty_dB;
        end

        function gain = patternGain(obj, phi, phi_b)
            d = obj.wrapToPi(phi - phi_b);

            sigma = deg2rad(obj.beamwidth3dB_deg) / 2.355;
            main = obj.mainLobeGain_dB * exp(-(d.^2)/(2*sigma^2));

            gain = max(main, obj.sideLobeGain_dB);
        end

        function a = wrapToPi(~, a)
            a = mod(a + pi, 2*pi) - pi;
        end
    end
end

