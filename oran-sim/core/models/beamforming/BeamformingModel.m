classdef BeamformingModel
%BEAMFORMINGMODEL System-level beamforming gain model
%
% Reads:
%   ctx.uePos [numUE x 3]
%   ctx.scenario.topology.gNBPos [numCell x 3]
%   ctx.action.beam.ueBeamId [numUE x 1] (optional)
%
% Writes:
%   ctx.tmp.beamGain_dB [numUE x numCell]
%
% Usage:
%   ctx = beam.step(ctx);
%   RadioModel should add ctx.tmp.beamGain_dB into RSRP.

    properties
        numBeamPerCell
        beamAzimuth_rad          % [numCell x numBeam]
        mainLobeGain_dB
        sideLobeGain_dB
        beamwidth3dB_deg
        mismatchPenalty_dB       % penalty when UE does not control beam
        defaultPolicy            % "best" | "slightly_suboptimal" | "random"
        perCellSeed
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
        end

        function obj = initialize(obj, ctx)
            numCell = ctx.cfg.scenario.numCell;
            nb = obj.numBeamPerCell;

            obj.beamAzimuth_rad = zeros(numCell, nb);

            % Uniform beams in [-pi, pi)
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

            gNB = ctx.scenario.topology.gNBPos;

            if ~isfield(ctx,'tmp') || isempty(ctx.tmp)
                ctx.tmp = struct();
            end
            ctx.tmp.beamGain_dB = zeros(numUE, numCell);

            % Read action
            ueBeamId = zeros(numUE,1);
            hasControl = false(numUE,1);

            if ~isempty(ctx.action) && isfield(ctx.action,'beam') && ...
                    isfield(ctx.action.beam,'ueBeamId')
                v = ctx.action.beam.ueBeamId;
                if isnumeric(v) && numel(v)==numUE
                    ueBeamId = round(v(:));
                    ueBeamId(ueBeamId < 0) = 0;
                    hasControl = ueBeamId > 0;
                end
            end

            % Compute gain per UE per cell
            for u = 1:numUE
                for c = 1:numCell

                    % UE direction (azimuth) as seen from cell c
                    dx = ctx.uePos(u,1) - gNB(c,1);
                    dy = ctx.uePos(u,2) - gNB(c,2);
                    phi = atan2(dy, dx); % [-pi,pi]

                    if hasControl(u)
                        b = mod(ueBeamId(u)-1, obj.numBeamPerCell) + 1;
                        phi_b = obj.beamAzimuth_rad(c,b);
                        gain = obj.patternGain(phi, phi_b);
                    else
                        gain = obj.defaultGain(phi, c);
                    end

                    ctx.tmp.beamGain_dB(u,c) = gain;
                end
            end
        end
    end

    methods (Access = private)

        function gain = defaultGain(obj, phi, c)
            nb = obj.numBeamPerCell;

            % choose best beam as baseline
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
                b = randi(nb);
                gain = obj.patternGain(phi, obj.beamAzimuth_rad(c,b));
                gain = gain - obj.mismatchPenalty_dB;
                return;
            end

            % slightly_suboptimal:
            % take best beam then subtract a small penalty to mimic imperfect baseline
            gain = best - obj.mismatchPenalty_dB;
        end

        function gain = patternGain(obj, phi, phi_b)
            % Mainlobe/side-lobe smooth pattern:
            % Use wrapped angle error and a Gaussian-like mainlobe.
            d = obj.wrapToPi(phi - phi_b);

            sigma = deg2rad(obj.beamwidth3dB_deg) / 2.355; % 3dB width -> sigma
            main = obj.mainLobeGain_dB * exp(-(d.^2)/(2*sigma^2));

            % clamp to sidelobe floor
            gain = max(main, obj.sideLobeGain_dB);
        end

        function a = wrapToPi(~, a)
            a = mod(a + pi, 2*pi) - pi;
        end
    end
end
