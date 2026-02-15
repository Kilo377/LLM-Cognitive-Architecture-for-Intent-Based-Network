classdef RadioModel
%RADIOMODEL Enhanced system-level radio model
%
% Features:
%   - Pathloss (log-distance)
%   - Log-normal shadowing
%   - Thermal noise
%   - Inter-cell interference
%   - Cell Tx power control offset
%   - Post-HO SINR penalty support
%
% Output:
%   ctx.rsrp_dBm
%   ctx.sinr_dB

    properties
        pathlossExp
        shadowingStd_dB
        noiseFigure_dB
        temperature_K
    end

    methods
        function obj = RadioModel()

            obj.pathlossExp    = 3.5;   % urban macro
            obj.shadowingStd_dB = 6;    % log-normal shadowing
            obj.noiseFigure_dB = 7;     % receiver NF
            obj.temperature_K  = 290;   % standard temperature
        end

        function ctx = step(obj, ctx)

            numUE   = ctx.cfg.scenario.numUE;
            numCell = ctx.cfg.scenario.numCell;

            gNB = ctx.scenario.topology.gNBPos;

            % Tx power per cell (include power control offset if exists)
            txPower_dBm = ctx.txPowerCell_dBm * ones(numCell,1);

            if ~isempty(ctx.action) && isfield(ctx.action,'power')
                if isfield(ctx.action.power,'cellTxPowerOffset_dB')
                    offset = ctx.action.power.cellTxPowerOffset_dB;
                    if numel(offset) == numCell
                        txPower_dBm = txPower_dBm + offset(:);
                    end
                end
            end

            % Allocate RSRP matrix
            rsrp = zeros(numUE, numCell);

            % Bandwidth and noise
            BW = ctx.bandwidthHz;
            k_B = 1.38e-23;
            noisePower_W = k_B * obj.temperature_K * BW;
            noisePower_dBm = 10*log10(noisePower_W) + 30 + obj.noiseFigure_dB;

            for c = 1:numCell

                d = vecnorm(ctx.uePos - gNB(c,:), 2, 2);
                d = max(d,1);

                % Log-distance pathloss
                pl_dB = 10*obj.pathlossExp*log10(d);

                % Shadowing
                shadow_dB = obj.shadowingStd_dB * randn(numUE,1);

                rsrp(:,c) = txPower_dBm(c) - pl_dB + shadow_dB;
            end

            ctx.rsrp_dBm = rsrp;

            % SINR calculation
            sinr = zeros(numUE,1);

            for u = 1:numUE

                s = ctx.servingCell(u);

                % Signal power
                signal_dBm = rsrp(u,s);
                signal_W = 10.^((signal_dBm-30)/10);

                % Interference from other cells
                interf_dBm = rsrp(u,:);
                interf_dBm(s) = -inf;

                interf_W = sum(10.^((interf_dBm-30)/10));

                noise_W = 10.^((noisePower_dBm-30)/10);

                sinr_W = signal_W / (interf_W + noise_W + 1e-15);

                sinr(u) = 10*log10(sinr_W);
            end

            ctx.sinr_dB = sinr;

            % ===============================
            % Apply Post-HO SINR penalty
            % ===============================
            if isfield(ctx,'uePostHoUntilSlot')

                for u = 1:numUE
                    if ctx.slot < ctx.uePostHoUntilSlot(u)
                        ctx.sinr_dB(u) = ...
                            ctx.sinr_dB(u) - ctx.uePostHoSinrPenalty_dB(u);
                    else
                        ctx.uePostHoSinrPenalty_dB(u) = 0;
                    end
                end
            end

        end
    end
end
