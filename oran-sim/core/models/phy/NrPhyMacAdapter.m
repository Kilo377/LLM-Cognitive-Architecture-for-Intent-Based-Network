classdef NrPhyMacAdapter
%NRPHYMACADAPTER v3 (HARQ-consistent + ctrl-safe debug + servedBits fixed)
%
% Fixes vs v2:
%   1) Served bits is CONSISTENT with stochastic decoding result:
%        - success -> servedBits = TBS
%        - fail    -> servedBits = 0
%      (v2 used random success but returned expectation TBS*(1-BLER) -> bug)
%
%   2) HARQ state is per UE and stable:
%        - harqRound: 1..harqMaxTx
%        - harqCombiningGain_dB accumulates only on failures
%        - harqActive marks TB pending
%
%   3) Debug interface unified:
%        - setDebug(enable, firstSlots)
%        - optionally read schedInfo.slot
%        - store lastDebug(u) fields
%
% Inputs:
%   schedInfo.ueId
%   schedInfo.numPRB
%   schedInfo.mcs (optional)
%   schedInfo.slot (optional, for debug printing)
%   radioMeas.sinr_dB
%
% Outputs:
%   getServedBits(ueId): delivered bits for this scheduling (0 or TBS)
%   lastMCS / lastBLER / lastTBS_bits / lastServedBits

    properties
        cfg
        numUE
        numCell

        % HARQ
        rvSequence
        harqMaxTx
        harqRound                % [numUE x 1]
        harqCombiningGain_dB     % [numUE x 1]
        harqActive               % [numUE x 1]

        % Cache (per scheduling)
        lastTBS_bits             % [numUE x 1]
        lastBLER                 % [numUE x 1]
        lastMCS                  % [numUE x 1]
        lastServedBits           % [numUE x 1]

        % Debug
        debugEnable
        debugFirstSlots
        lastDebug                % struct array [numUE x 1]
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

            obj.lastTBS_bits    = zeros(obj.numUE,1);
            obj.lastBLER        = zeros(obj.numUE,1);
            obj.lastMCS         = zeros(obj.numUE,1);
            obj.lastServedBits  = zeros(obj.numUE,1);

            obj.debugEnable     = false;
            obj.debugFirstSlots = 3;
            obj.lastDebug       = repmat(obj.makeEmptyDebug(), obj.numUE, 1);
        end

        function obj = setDebug(obj, enable, firstSlots)
            if nargin < 2, enable = true; end
            if nargin < 3, firstSlots = obj.debugFirstSlots; end
            obj.debugEnable = logical(enable);
            obj.debugFirstSlots = max(0, round(firstSlots));
        end

        function obj = resetUE(obj, ueId)
            u = round(ueId);
            if u < 1 || u > obj.numUE
                return;
            end
            obj.harqRound(u)            = 1;
            obj.harqCombiningGain_dB(u) = 0;
            obj.harqActive(u)           = false;

            obj.lastTBS_bits(u)   = 0;
            obj.lastBLER(u)       = 0;
            obj.lastMCS(u)        = 0;
            obj.lastServedBits(u) = 0;
            obj.lastDebug(u)      = obj.makeEmptyDebug();
        end

        function obj = step(obj, schedInfo, radioMeas)

            % -------- guards --------
            if ~isfield(schedInfo,'ueId') || ~isfield(schedInfo,'numPRB')
                return;
            end

            u = round(schedInfo.ueId);
            prb = round(schedInfo.numPRB);

            if u < 1 || u > obj.numUE
                return;
            end

            if prb <= 0
                obj.lastTBS_bits(u)   = 0;
                obj.lastBLER(u)       = 0;
                obj.lastMCS(u)        = 0;
                obj.lastServedBits(u) = 0;
                return;
            end

            sinr_dB = radioMeas.sinr_dB;

            % 1) SINR -> CQI
            cqi = obj.sinrToCQI(sinr_dB);

            % 2) CQI -> MCS (unless overridden)
            if isfield(schedInfo,'mcs') && ~isempty(schedInfo.mcs)
                mcs = round(schedInfo.mcs);
            else
                mcs = obj.cqiToMCS(cqi);
            end
            mcs = max(min(mcs,27),0);
            obj.lastMCS(u) = mcs;

            % 3) TBS
            tbs_bits = obj.computeTBS(mcs, prb);
            obj.lastTBS_bits(u) = tbs_bits;

            % 4) Effective SINR with HARQ combining
            effSinr_dB = sinr_dB;
            if obj.harqActive(u)
                effSinr_dB = effSinr_dB + obj.harqCombiningGain_dB(u);
            end

            % 5) BLER (for this attempt)
            bler = obj.estimateBLER(effSinr_dB, mcs);
            obj.lastBLER(u) = bler;

            % 6) Stochastic decode
            success = (rand() > bler);

            % 7) Served bits and HARQ update
            if success
                servedBits = tbs_bits;

                obj.harqRound(u)            = 1;
                obj.harqCombiningGain_dB(u) = 0;
                obj.harqActive(u)           = false;
            else
                servedBits = 0;

                obj.harqActive(u) = true;

                if obj.harqRound(u) < obj.harqMaxTx
                    obj.harqRound(u) = obj.harqRound(u) + 1;
                    obj.harqCombiningGain_dB(u) = obj.harqCombiningGain_dB(u) + 1.7;
                else
                    % HARQ fails after maxTx
                    obj.harqRound(u)            = 1;
                    obj.harqCombiningGain_dB(u) = 0;
                    obj.harqActive(u)           = false;

                    % mark failure explicitly
                    obj.lastBLER(u) = 1.0;
                end
            end

            obj.lastServedBits(u) = servedBits;

            % 8) Debug record + optional print
            slot = 0;
            if isfield(schedInfo,'slot') && ~isempty(schedInfo.slot)
                slot = double(schedInfo.slot);
            end

            obj.lastDebug(u).slot      = slot;
            obj.lastDebug(u).ueId      = u;
            obj.lastDebug(u).prb       = prb;
            obj.lastDebug(u).sinr_dB   = sinr_dB;
            obj.lastDebug(u).effSinr_dB= effSinr_dB;
            obj.lastDebug(u).cqi       = cqi;
            obj.lastDebug(u).mcs       = mcs;
            obj.lastDebug(u).tbs_bits  = tbs_bits;
            obj.lastDebug(u).bler      = obj.lastBLER(u);
            obj.lastDebug(u).success   = success;
            obj.lastDebug(u).harqRound = obj.harqRound(u);
            obj.lastDebug(u).harqGain_dB = obj.harqCombiningGain_dB(u);
            obj.lastDebug(u).harqActive  = obj.harqActive(u);

            if obj.debugEnable && slot > 0 && slot <= obj.debugFirstSlots
                %disp("[NrPhyMacAdapter] slot=" + slot + ...
                %    " u=" + u + " prb=" + prb + ...
                %    " sinr=" + sinr_dB + " eff=" + effSinr_dB + ...
                %    " mcs=" + mcs + " bler=" + obj.lastBLER(u) + ...
                %    " ok=" + success + " bits=" + servedBits + ...
                %    " harqRound=" + obj.harqRound(u) + " harqGain=" + obj.harqCombiningGain_dB(u));
            end
        end

        function bits = getServedBits(obj, ueId)
            u = round(ueId);
            if u < 1 || u > obj.numUE
                bits = 0;
                return;
            end
            bits = obj.lastServedBits(u);
        end
    end

    methods (Access = private)

        function d = makeEmptyDebug(~)
            d = struct( ...
                'slot',0,'ueId',0,'prb',0, ...
                'sinr_dB',0,'effSinr_dB',0, ...
                'cqi',0,'mcs',0, ...
                'tbs_bits',0,'bler',0,'success',false, ...
                'harqRound',0,'harqGain_dB',0,'harqActive',false);
        end

        function cqi = sinrToCQI(~, sinr_dB)
            th = [-6 -4 -2 0 2 4 6 8 10 12 14 16 18 20 22];
            cqi = find(sinr_dB < th,1) - 1;
            if isempty(cqi), cqi = 15; end
            cqi = max(min(cqi,15),1);
        end

        function mcs = cqiToMCS(~, cqi)
            mcs = round((cqi-1) * (27/14));
            mcs = max(min(mcs,27),0);
        end

        function tbs_bits = computeTBS(~, mcs, numPRB)
            [Qm, R] = localMcsToModCod(mcs);

            Nre = 12 * 14;
            overhead = 0.25;
            NreEff = floor(Nre * (1-overhead));

            tbs_bits = floor(numPRB * NreEff * Qm * R);
            tbs_bits = max(tbs_bits, 0);
        end

        function bler = estimateBLER(~, sinr_dB, mcs)
            [sinr_th, k] = localBlerParams(mcs);
            bler = 1 ./ (1 + exp(k * (sinr_dB - sinr_th)));
            bler = min(max(bler,0),1);
        end
    end
end

function [Qm, R] = localMcsToModCod(mcs)

if mcs <= 4
    Qm = 2;  R = 0.12 + 0.08*mcs;
elseif mcs <= 10
    Qm = 2;  R = 0.45 + 0.03*(mcs-5);
elseif mcs <= 17
    Qm = 4;  R = 0.35 + 0.04*(mcs-11);
elseif mcs <= 23
    Qm = 6;  R = 0.35 + 0.04*(mcs-18);
else
    Qm = 8;  R = 0.45 + 0.03*(mcs-24);
end

R = min(max(R, 0.05), 0.95);
end

function [sinr_th, k] = localBlerParams(mcs)
sinr_th = -7 + 0.9*mcs;
k       = 0.9 + 0.02*mcs;
k       = min(k, 1.6);
end
