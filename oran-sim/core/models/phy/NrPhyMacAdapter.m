
classdef NrPhyMacAdapter
%NRPHYMACADAPTER Minimal PHY/MAC adapter using 5G Toolbox abstractions
%   - SINR -> CQI -> MCS
%   - MCS + PRB -> TBS
%   - BLER model
%   - Output: successfully delivered bits

    properties
        cfg
        numUE
        numCell

        % PHY parameters
        nLayers
        rvSequence

        % Runtime buffers
        lastTBS_bits      % [numUE x 1]
        lastBLER          % [numUE x 1]
    end

    methods
        function obj = NrPhyMacAdapter(cfg, scenario)
            obj.cfg     = cfg;
            obj.numUE   = cfg.scenario.numUE;
            obj.numCell = cfg.scenario.numCell;

            % Assume single layer DL for now
            obj.nLayers = 1;
            obj.rvSequence = [0 2 3 1];

            obj.lastTBS_bits = zeros(obj.numUE,1);
            obj.lastBLER     = zeros(obj.numUE,1);
        end

        function obj = step(obj, schedInfo, radioMeas)
            %STEP One PHY/MAC step for one scheduled UE
            %
            % schedInfo:
            %   .ueId
            %   .numPRB
            %   .mcs (optional, can be empty)
            %
            % radioMeas:
            %   .sinr_dB

            u = schedInfo.ueId;
            sinr_dB = radioMeas.sinr_dB;

            % 1) SINR -> CQI
            cqi = obj.sinrToCQI(sinr_dB);

            % 2) CQI -> MCS
            if isfield(schedInfo, 'mcs') && ~isempty(schedInfo.mcs)
                mcs = schedInfo.mcs;
            else
                mcs = obj.cqiToMCS(cqi);
            end

            % 3) MCS + PRB -> TBS
            tbs_bits = obj.computeTBS(mcs, schedInfo.numPRB);

            % 4) BLER estimation
            bler = obj.estimateBLER(sinr_dB, mcs);

            % Cache
            obj.lastTBS_bits(u) = tbs_bits;
            obj.lastBLER(u)     = bler;
        end

        function bits = getServedBits(obj, ueId)
            % Return successfully delivered bits
            bits = obj.lastTBS_bits(ueId) * (1 - obj.lastBLER(ueId));
        end
    end

    methods (Access = private)

        function cqi = sinrToCQI(~, sinr_dB)
            % Simple 3GPP-like mapping
            % CQI 1~15

            cqiTable = [-5, -2, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25];
            cqi = find(sinr_dB < cqiTable, 1) - 1;
            if isempty(cqi)
                cqi = 15;
            end
            cqi = max(min(cqi,15),1);
        end

        function mcs = cqiToMCS(~, cqi)
            % Very standard mapping: MCS ~= CQI - 1
            mcs = max(cqi - 1, 0);
        end

        function tbs_bits = computeTBS(~, mcs, numPRB)
            % Wrapper of 5G Toolbox TBS calculation

            % Assumptions (baseline)
            modOrderTable = [ ...
                2 2 2 2 2 4 4 4 4 6 6 6 6 6 8 8 8 8 8 ...
            ];
            codeRateTable = [ ...
                120 193 308 449 602 378 434 490 553 ...
                616 466 517 567 616 666 719 772 822 873 ...
            ] / 1024;

            idx = min(mcs+1, numel(modOrderTable));
            Qm  = modOrderTable(idx);
            R   = codeRateTable(idx);

            % Resource elements per PRB (approximate)
            Nre = 12 * 14 * 0.75; % remove pilots

            tbs_bits = floor(numPRB * Nre * Qm * R);
        end

        function bler = estimateBLER(~, sinr_dB, mcs)
            % Simple logistic BLER curve per MCS
            % This is where you can later plug helperNR BLER curves

            sinr_th = -5 + 1.5 * mcs;
            k = 1.0;

            bler = 1 ./ (1 + exp(k * (sinr_dB - sinr_th)));
            bler = min(max(bler, 0), 1);
        end
    end
end
