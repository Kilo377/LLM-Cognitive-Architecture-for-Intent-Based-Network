classdef NrPhyMacAdapter
%NRPHYMACADAPTER v2: PHY/MAC adapter with HARQ memory and improved BLER/TBS
%
% Inputs:
%   schedInfo.ueId
%   schedInfo.numPRB
%   schedInfo.mcs (optional)
%   radioMeas.sinr_dB
%
% Outputs:
%   getServedBits(ueId): successfully delivered bits for this UE in this call
%
% Notes:
%   - This is still a system-level abstraction.
%   - It adds HARQ combining memory so repeated failures matter.
%   - It uses a more realistic BLER shape per MCS.

    properties
        cfg
        numUE
        numCell

        % HARQ
        rvSequence
        harqMaxTx                % max transmissions per TB
        harqRound                % [numUE x 1] current HARQ round (1..harqMaxTx)
        harqCombiningGain_dB     % [numUE x 1] accumulated combining gain
        harqActive               % [numUE x 1] whether a TB is pending retransmission

        % Cache
        lastTBS_bits             % [numUE x 1]
        lastBLER                 % [numUE x 1]
        lastMCS                  % [numUE x 1]
    end

    methods
        function obj = NrPhyMacAdapter(cfg, scenario) %#ok<INUSD>
            obj.cfg     = cfg;
            obj.numUE   = cfg.scenario.numUE;
            obj.numCell = cfg.scenario.numCell;

            obj.rvSequence = [0 2 3 1];
            obj.harqMaxTx  = 4;

            obj.harqRound            = ones(obj.numUE,1);
            obj.harqCombiningGain_dB = zeros(obj.numUE,1);
            obj.harqActive           = false(obj.numUE,1);

            obj.lastTBS_bits = zeros(obj.numUE,1);
            obj.lastBLER     = zeros(obj.numUE,1);
            obj.lastMCS      = zeros(obj.numUE,1);
        end

        function obj = step(obj, schedInfo, radioMeas)

            u = schedInfo.ueId;
            prb = schedInfo.numPRB;

            sinr_dB = radioMeas.sinr_dB;

            % 1) SINR -> CQI
            cqi = obj.sinrToCQI(sinr_dB);

            % 2) CQI -> MCS (unless overridden)
            if isfield(schedInfo,'mcs') && ~isempty(schedInfo.mcs)
                mcs = schedInfo.mcs;
            else
                mcs = obj.cqiToMCS(cqi);
            end
            obj.lastMCS(u) = mcs;

            % 3) TBS
            tbs_bits = obj.computeTBS(mcs, prb);
            obj.lastTBS_bits(u) = tbs_bits;

            % 4) Effective SINR with HARQ combining
            effSinr_dB = sinr_dB + obj.harqCombiningGain_dB(u);

            % 5) BLER
            bler = obj.estimateBLER(effSinr_dB, mcs);
            obj.lastBLER(u) = bler;

            % 6) Update HARQ state using a stochastic decode outcome
            %    Decode success probability = 1 - BLER
            success = (rand() > bler);

            if success
                % TB delivered. Reset HARQ memory.
                obj.harqRound(u)            = 1;
                obj.harqCombiningGain_dB(u) = 0;
                obj.harqActive(u)           = false;
            else
                % TB not delivered. Start/continue HARQ.
                obj.harqActive(u) = true;

                if obj.harqRound(u) < obj.harqMaxTx
                    obj.harqRound(u) = obj.harqRound(u) + 1;
                    % Soft-combining gain. Approx 1.5~2 dB per extra round.
                    obj.harqCombiningGain_dB(u) = obj.harqCombiningGain_dB(u) + 1.7;
                else
                    % HARQ failed after maxTx. Drop TB at PHY.
                    % Reset state. Upper layers may see this as "no delivery".
                    obj.harqRound(u)            = 1;
                    obj.harqCombiningGain_dB(u) = 0;
                    obj.harqActive(u)           = false;

                    % Force extremely low delivery for this attempt
                    % Keep lastBLER high so served bits becomes small.
                    obj.lastBLER(u) = 1.0;
                end
            end
        end

        function bits = getServedBits(obj, ueId)
            % Served bits for this scheduling opportunity
            bits = obj.lastTBS_bits(ueId) * (1 - obj.lastBLER(ueId));
        end
    end

    methods (Access = private)

        function cqi = sinrToCQI(~, sinr_dB)
            % A light-weight CQI mapping
            th = [-6 -4 -2 0 2 4 6 8 10 12 14 16 18 20 22];
            cqi = find(sinr_dB < th,1) - 1;
            if isempty(cqi), cqi = 15; end
            cqi = max(min(cqi,15),1);
        end

        function mcs = cqiToMCS(~, cqi)
            % Keep it simple but more reasonable:
            % map CQI 1..15 -> MCS 0..27 (cap)
            mcs = round((cqi-1) * (27/14));
            mcs = max(min(mcs,27),0);
        end

        function tbs_bits = computeTBS(~, mcs, numPRB)
            % System-level TBS approximation
            % Use MCS -> (Qm, R) table (rough 3GPP-like shape)
            % numPRB -> REs -> bits
            [Qm, R] = localMcsToModCod(mcs);

            % RE per PRB per slot (DL), remove pilots/overheads
            Nre = 12 * 14;
            overhead = 0.25;
            NreEff = floor(Nre * (1-overhead));

            tbs_bits = floor(numPRB * NreEff * Qm * R);
            tbs_bits = max(tbs_bits, 0);
        end

        function bler = estimateBLER(~, sinr_dB, mcs)
            % More realistic BLER family:
            % Each MCS has a threshold and slope.
            [sinr_th, k] = localBlerParams(mcs);

            bler = 1 ./ (1 + exp(k * (sinr_dB - sinr_th)));
            bler = min(max(bler,0),1);
        end
    end
end

function [Qm, R] = localMcsToModCod(mcs)
% Rough mapping for system-level simulation
% Qm: modulation order (2,4,6,8)
% R : code rate (0..1)

% Piecewise
if mcs <= 4
    Qm = 2;  R = 0.12 + 0.08*mcs;         % QPSK low rate
elseif mcs <= 10
    Qm = 2;  R = 0.45 + 0.03*(mcs-5);     % QPSK mid
elseif mcs <= 17
    Qm = 4;  R = 0.35 + 0.04*(mcs-11);    % 16QAM
elseif mcs <= 23
    Qm = 6;  R = 0.35 + 0.04*(mcs-18);    % 64QAM
else
    Qm = 8;  R = 0.45 + 0.03*(mcs-24);    % 256QAM
end

R = min(max(R, 0.05), 0.95);
end

function [sinr_th, k] = localBlerParams(mcs)
% BLER curve parameters per MCS
% sinr_th increases with MCS
% slope k becomes slightly steeper with MCS

sinr_th = -7 + 0.9*mcs;        % threshold trend
k       = 0.9 + 0.02*mcs;      % slope trend
k       = min(k, 1.6);
end
