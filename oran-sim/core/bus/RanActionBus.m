classdef RanActionBus
%RANACTIONBUS Stable control interface for modular ORAN-SIM
%
% Principles:
%   - Only RIC writes this
%   - Kernel never validates
%   - validate() is the only legal guard
%   - Add-only evolution rule

    methods (Static)

        %% ===============================
        % Initialize
        %% ===============================
        function action = init(cfg)

            numCell = cfg.scenario.numCell;
            numUE   = cfg.scenario.numUE;

            action = struct();

            %% -------- Scheduling --------
            action.scheduling = struct();
            action.scheduling.selectedUE = zeros(numCell,1);   % legacy
            action.scheduling.weightUE   = ones(numUE,1);      % QoS weight override

            %% -------- Power --------
            action.power = struct();
            action.power.cellTxPowerOffset_dB = zeros(numCell,1);

            %% -------- Sleep --------
            action.sleep = struct();
            action.sleep.cellSleepState = zeros(numCell,1);    % 0/1/2

            %% -------- Handover --------
            action.handover = struct();
            action.handover.hysteresisOffset_dB = zeros(numCell,1);
            action.handover.tttOffset_slot      = zeros(numCell,1);

            %% -------- Beamforming --------
            action.beam = struct();
            action.beam.ueBeamId = zeros(numUE,1);
            action.beam.mode     = "static";  % reserved for future

            %% -------- QoS Control --------
            action.qos = struct();
            action.qos.servicePriority = struct( ...
                'eMBB', 1.0, ...
                'URLLC', 1.0, ...
                'mMTC', 1.0 );

            %% -------- Radio Control --------
            action.radio = struct();
            action.radio.bandwidthScale = ones(numCell,1); % 0~1
            action.radio.interferenceMitigation = false;

            %% -------- Energy Policy --------
            action.energy = struct();
            action.energy.basePowerScale = ones(numCell,1);

            %% -------- RLF Control --------
            action.rlf = struct();
            action.rlf.sinrThresholdOffset_dB = 0;

            %% -------- Reserved Extension --------
            action.ext = struct(); % future-proof bucket
        end

        %% ===============================
        % Validate
        %% ===============================
        function action = validate(action, cfg, state)

            numCell = cfg.scenario.numCell;
            numUE   = cfg.scenario.numUE;

            %% -------- Scheduling --------
            if ~isfield(action,'scheduling')
                action.scheduling = struct();
            end

            if ~isfield(action.scheduling,'selectedUE') || ...
               numel(action.scheduling.selectedUE) ~= numCell
                action.scheduling.selectedUE = zeros(numCell,1);
            else
                sel = round(action.scheduling.selectedUE(:));
                sel(sel < 0) = 0;
                sel(sel > numUE) = 0;

                % must belong to serving cell
                for c = 1:numCell
                    u = sel(c);
                    if u>0 && state.ue.servingCell(u) ~= c
                        sel(c) = 0;
                    end
                end
                action.scheduling.selectedUE = sel;
            end

            if ~isfield(action.scheduling,'weightUE') || ...
               numel(action.scheduling.weightUE) ~= numUE
                action.scheduling.weightUE = ones(numUE,1);
            else
                w = action.scheduling.weightUE(:);
                w(w<0) = 0;
                w(w>10) = 10;
                action.scheduling.weightUE = w;
            end

            %% -------- Power --------
            if ~isfield(action,'power') || ...
               numel(action.power.cellTxPowerOffset_dB) ~= numCell
                action.power.cellTxPowerOffset_dB = zeros(numCell,1);
            else
                action.power.cellTxPowerOffset_dB = ...
                    max(min(action.power.cellTxPowerOffset_dB(:), 10), -10);
            end

            %% -------- Sleep --------
            if ~isfield(action,'sleep') || ...
               numel(action.sleep.cellSleepState) ~= numCell
                action.sleep.cellSleepState = zeros(numCell,1);
            else
                s = round(action.sleep.cellSleepState(:));
                s(s<0)=0; s(s>2)=2;
                action.sleep.cellSleepState = s;
            end

            %% -------- Handover --------
            if ~isfield(action,'handover')
                action.handover = struct();
            end

            if ~isfield(action.handover,'hysteresisOffset_dB') || ...
               numel(action.handover.hysteresisOffset_dB) ~= numCell
                action.handover.hysteresisOffset_dB = zeros(numCell,1);
            else
                action.handover.hysteresisOffset_dB = ...
                    max(min(action.handover.hysteresisOffset_dB(:),5),-5);
            end

            if ~isfield(action.handover,'tttOffset_slot') || ...
               numel(action.handover.tttOffset_slot) ~= numCell
                action.handover.tttOffset_slot = zeros(numCell,1);
            else
                action.handover.tttOffset_slot = ...
                    max(min(round(action.handover.tttOffset_slot(:)),10),-5);
            end

            %% -------- Beam --------
            if ~isfield(action,'beam') || ...
               numel(action.beam.ueBeamId) ~= numUE
                action.beam.ueBeamId = zeros(numUE,1);
            else
                b = round(action.beam.ueBeamId(:));
                b(b<0)=0;
                action.beam.ueBeamId = b;
            end

            %% -------- QoS --------
            if ~isfield(action,'qos')
                action.qos.servicePriority = struct('eMBB',1,'URLLC',1,'mMTC',1);
            end

            %% -------- Radio --------
            if ~isfield(action,'radio') || ...
               numel(action.radio.bandwidthScale) ~= numCell
                action.radio.bandwidthScale = ones(numCell,1);
            else
                bs = action.radio.bandwidthScale(:);
                bs(bs<0)=0; bs(bs>1)=1;
                action.radio.bandwidthScale = bs;
            end

            %% -------- Energy --------
            if ~isfield(action,'energy') || ...
               numel(action.energy.basePowerScale) ~= numCell
                action.energy.basePowerScale = ones(numCell,1);
            else
                s = action.energy.basePowerScale(:);
                s(s<0.2)=0.2; s(s>1.2)=1.2;
                action.energy.basePowerScale = s;
            end

            %% -------- RLF --------
            if ~isfield(action,'rlf')
                action.rlf.sinrThresholdOffset_dB = 0;
            else
                action.rlf.sinrThresholdOffset_dB = ...
                    max(min(action.rlf.sinrThresholdOffset_dB,5),-5);
            end
        end
    end
end
