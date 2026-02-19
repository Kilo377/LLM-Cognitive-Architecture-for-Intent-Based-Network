classdef RanActionBus
% RANACTIONBUS v3 (Aligned with ctrl architecture)
%
% Principles:
%   - RIC writes only
%   - Kernel reads only
%   - validate() is the only guard
%   - Field names aligned 1:1 with ctx.ctrl
%   - Add-only evolution

    methods (Static)

        %% =========================================================
        % INIT
        %% =========================================================
        function action = init(cfg)

            numCell = cfg.scenario.numCell;
            numUE   = cfg.scenario.numUE;

            action = struct();

            %% =====================================================
            % Scheduling
            %% =====================================================
            action.scheduling.selectedUE = zeros(numCell,1);
            action.scheduling.weightUE   = ones(numUE,1);

            %% =====================================================
            % Radio
            %% =====================================================
            action.radio.bandwidthScale      = ones(numCell,1);
            action.radio.txPowerOffset_dB    = zeros(numCell,1);
            action.radio.interferenceCouplingFactor = 1.0; % NEW

            %% =====================================================
            % Energy
            %% =====================================================
            action.energy.basePowerScale = ones(numCell,1);

            %% =====================================================
            % Sleep
            %% =====================================================
            action.sleep.cellSleepState = zeros(numCell,1);

            %% =====================================================
            % Handover
            %% =====================================================
            action.handover.hysteresisOffset_dB = zeros(numCell,1);
            action.handover.tttOffset_slot      = zeros(numCell,1);

            %% =====================================================
            % Beam
            %% =====================================================
            action.beam.ueBeamId = zeros(numUE,1);
            action.beam.mode     = "static";

            %% =====================================================
            % RLF
            %% =====================================================
            action.rlf.sinrThresholdOffset_dB = 0;

            %% =====================================================
            % QoS
            %% =====================================================
            action.qos.servicePriority = struct( ...
                'eMBB', 1.0, ...
                'URLLC', 1.0, ...
                'mMTC', 1.0 );

            %% =====================================================
            % Debug control (NEW)
            %% =====================================================
            action.debug.enableVerbose = false;
            action.debug.printSlot     = 0;  % 0=all, else only this slot

            %% =====================================================
            % Reserved
            %% =====================================================
            action.ext = struct();
        end


        %% =========================================================
        % VALIDATE
        %% =========================================================
        function action = validate(action, cfg, state)

            numCell = cfg.scenario.numCell;
            numUE   = cfg.scenario.numUE;

            %% ===============================
            % Scheduling
            %% ===============================
            if ~isfield(action,'scheduling')
                action.scheduling = struct();
            end

            sel = zeros(numCell,1);
            if isfield(action.scheduling,'selectedUE') && ...
               numel(action.scheduling.selectedUE)==numCell

                tmp = round(action.scheduling.selectedUE(:));
                tmp(tmp<0)=0;
                tmp(tmp>numUE)=0;

                for c=1:numCell
                    u = tmp(c);
                    if u>0 && state.ue.servingCell(u)==c
                        sel(c)=u;
                    end
                end
            end
            action.scheduling.selectedUE = sel;

            if ~isfield(action.scheduling,'weightUE') || ...
               numel(action.scheduling.weightUE)~=numUE
                action.scheduling.weightUE = ones(numUE,1);
            else
                w = action.scheduling.weightUE(:);
                w(w<0)=0; w(w>10)=10;
                action.scheduling.weightUE = w;
            end

            %% ===============================
            % Radio
            %% ===============================
            if ~isfield(action,'radio')
                action.radio = struct();
            end

            % bandwidth
            if ~isfield(action.radio,'bandwidthScale') || ...
               numel(action.radio.bandwidthScale)~=numCell
                action.radio.bandwidthScale = ones(numCell,1);
            else
                bs = action.radio.bandwidthScale(:);
                bs(bs<0)=0; bs(bs>1)=1;
                action.radio.bandwidthScale = bs;
            end

            % tx power
            if ~isfield(action.radio,'txPowerOffset_dB') || ...
               numel(action.radio.txPowerOffset_dB)~=numCell
                action.radio.txPowerOffset_dB = zeros(numCell,1);
            else
                v = action.radio.txPowerOffset_dB(:);
                v(v<-10)=-10; v(v>10)=10;
                action.radio.txPowerOffset_dB = v;
            end

            % interference coupling
            if ~isfield(action.radio,'interferenceCouplingFactor')
                action.radio.interferenceCouplingFactor = 1.0;
            else
                f = action.radio.interferenceCouplingFactor;
                f = max(min(f,3.0),0.1);
                action.radio.interferenceCouplingFactor = f;
            end

            %% ===============================
            % Energy
            %% ===============================
            if ~isfield(action,'energy') || ...
               numel(action.energy.basePowerScale)~=numCell
                action.energy.basePowerScale = ones(numCell,1);
            else
                s = action.energy.basePowerScale(:);
                s(s<0.2)=0.2; s(s>1.5)=1.5;
                action.energy.basePowerScale = s;
            end

            %% ===============================
            % Sleep
            %% ===============================
            if ~isfield(action,'sleep') || ...
               numel(action.sleep.cellSleepState)~=numCell
                action.sleep.cellSleepState = zeros(numCell,1);
            else
                s = round(action.sleep.cellSleepState(:));
                s(s<0)=0; s(s>2)=2;
                action.sleep.cellSleepState = s;
            end

            %% ===============================
            % Beam
            %% ===============================
            if ~isfield(action,'beam') || ...
               numel(action.beam.ueBeamId)~=numUE
                action.beam.ueBeamId = zeros(numUE,1);
            else
                b = round(action.beam.ueBeamId(:));
                b(b<0)=0;
                action.beam.ueBeamId = b;
            end

            %% ===============================
            % RLF
            %% ===============================
            if ~isfield(action,'rlf')
                action.rlf.sinrThresholdOffset_dB = 0;
            else
                v = action.rlf.sinrThresholdOffset_dB;
                action.rlf.sinrThresholdOffset_dB = max(min(v,5),-5);
            end

            %% ===============================
            % Debug
            %% ===============================
            if ~isfield(action,'debug')
                action.debug.enableVerbose = false;
                action.debug.printSlot     = 0;
            end
        end
    end
end
