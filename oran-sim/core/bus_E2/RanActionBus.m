%{
Author: Chongyu Bao (zt25108@bristol.ac.uk)

File: RanActionBus.m

Description:
RAN action bus (research mode).
This version expands action parameter limits.
It keeps add-only evolution.
It validates action fields for kernel safety.
It allows larger bandwidth and power actions for xApp research.
%}

classdef RanActionBus
% RANACTIONBUS v4 (Research Mode, Expanded Limits)
%
% Principles:
%   - RIC writes only
%   - Kernel reads only
%   - validate() is the only guard
%   - Field names aligned 1:1 with ctx.ctrl
%   - Add-only evolution
%
% Research changes:
%   - bandwidthScale upper bound increased
%   - txPowerOffset upper bound increased
%   - interferenceCouplingFactor range increased
%   - energy.basePowerScale range increased
%   - weightUE upper bound increased
%

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
            action.radio.bandwidthScale            = ones(numCell,1);
            action.radio.txPowerOffset_dB          = zeros(numCell,1);
            action.radio.interferenceCouplingFactor = 1.0;

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
            % Debug control
            %% =====================================================
            action.debug.enableVerbose = false;
            action.debug.printSlot     = 0;

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

                for c = 1:numCell
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
                w(w<0)=0;
                w(w>100)=100;
                action.scheduling.weightUE = w;
            end

            %% ===============================
            % Radio
            %% ===============================
            if ~isfield(action,'radio')
                action.radio = struct();
            end

            % bandwidth scale (research mode)
            if ~isfield(action.radio,'bandwidthScale') || ...
               numel(action.radio.bandwidthScale)~=numCell
                action.radio.bandwidthScale = ones(numCell,1);
            else
                bs = action.radio.bandwidthScale(:);
                bs(bs<0.05)=0.05;
                bs(bs>5.0)=5.0;
                action.radio.bandwidthScale = bs;
            end

            % tx power offset (research mode)
            if ~isfield(action.radio,'txPowerOffset_dB') || ...
               numel(action.radio.txPowerOffset_dB)~=numCell
                action.radio.txPowerOffset_dB = zeros(numCell,1);
            else
                v = action.radio.txPowerOffset_dB(:);
                v(v<-40)=-40;
                v(v>40)=40;
                action.radio.txPowerOffset_dB = v;
            end

            % interference coupling (research mode)
            if ~isfield(action.radio,'interferenceCouplingFactor')
                action.radio.interferenceCouplingFactor = 1.0;
            else
                f = action.radio.interferenceCouplingFactor;
                f = max(min(f,10.0),0.01);
                action.radio.interferenceCouplingFactor = f;
            end

            %% ===============================
            % Energy
            %% ===============================
            if ~isfield(action,'energy') || ...
               ~isfield(action.energy,'basePowerScale') || ...
               numel(action.energy.basePowerScale)~=numCell
                action.energy.basePowerScale = ones(numCell,1);
            else
                s = action.energy.basePowerScale(:);
                s(s<0.05)=0.05;
                s(s>5.0)=5.0;
                action.energy.basePowerScale = s;
            end

            %% ===============================
            % Sleep
            %% ===============================
            if ~isfield(action,'sleep') || ...
               ~isfield(action.sleep,'cellSleepState') || ...
               numel(action.sleep.cellSleepState)~=numCell
                action.sleep.cellSleepState = zeros(numCell,1);
            else
                s = round(action.sleep.cellSleepState(:));
                s(s<0)=0;
                s(s>2)=2;
                action.sleep.cellSleepState = s;
            end

            %% ===============================
            % Handover
            %% ===============================
            if ~isfield(action,'handover')
                action.handover = struct();
            end

            if ~isfield(action.handover,'hysteresisOffset_dB') || ...
               numel(action.handover.hysteresisOffset_dB)~=numCell
                action.handover.hysteresisOffset_dB = zeros(numCell,1);
            else
                h = action.handover.hysteresisOffset_dB(:);
                h(h<-10)=-10;
                h(h>20)=20;
                action.handover.hysteresisOffset_dB = h;
            end

            if ~isfield(action.handover,'tttOffset_slot') || ...
               numel(action.handover.tttOffset_slot)~=numCell
                action.handover.tttOffset_slot = zeros(numCell,1);
            else
                t = round(action.handover.tttOffset_slot(:));
                t(t<-50)=-50;
                t(t>200)=200;
                action.handover.tttOffset_slot = t;
            end

            %% ===============================
            % Beam
            %% ===============================
            if ~isfield(action,'beam')
                action.beam = struct();
            end

            if ~isfield(action.beam,'ueBeamId') || ...
               numel(action.beam.ueBeamId)~=numUE
                action.beam.ueBeamId = zeros(numUE,1);
            else
                b = round(action.beam.ueBeamId(:));
                b(b<0)=0;
                action.beam.ueBeamId = b;
            end

            if ~isfield(action.beam,'mode')
                action.beam.mode = "static";
            else
                m = string(action.beam.mode);
                if ~(m=="static" || m=="adaptive")
                    m = "static";
                end
                action.beam.mode = m;
            end

            %% ===============================
            % RLF
            %% ===============================
            if ~isfield(action,'rlf')
                action.rlf = struct();
                action.rlf.sinrThresholdOffset_dB = 0;
            else
                if ~isfield(action.rlf,'sinrThresholdOffset_dB')
                    action.rlf.sinrThresholdOffset_dB = 0;
                else
                    v = action.rlf.sinrThresholdOffset_dB;
                    action.rlf.sinrThresholdOffset_dB = max(min(v,20),-20);
                end
            end

            %% ===============================
            % QoS
            %% ===============================
            if ~isfield(action,'qos')
                action.qos = struct();
                action.qos.servicePriority = struct('eMBB',1.0,'URLLC',1.0,'mMTC',1.0);
            else
                if ~isfield(action.qos,'servicePriority')
                    action.qos.servicePriority = struct('eMBB',1.0,'URLLC',1.0,'mMTC',1.0);
                else
                    sp = action.qos.servicePriority;
                    if ~isfield(sp,'eMBB'),  sp.eMBB  = 1.0; end
                    if ~isfield(sp,'URLLC'), sp.URLLC = 1.0; end
                    if ~isfield(sp,'mMTC'),  sp.mMTC  = 1.0; end

                    sp.eMBB  = max(min(sp.eMBB,  10.0),0.0);
                    sp.URLLC = max(min(sp.URLLC, 10.0),0.0);
                    sp.mMTC  = max(min(sp.mMTC,  10.0),0.0);

                    action.qos.servicePriority = sp;
                end
            end

            %% ===============================
            % Debug
            %% ===============================
            if ~isfield(action,'debug')
                action.debug = struct();
                action.debug.enableVerbose = false;
                action.debug.printSlot     = 0;
            else
                if ~isfield(action.debug,'enableVerbose')
                    action.debug.enableVerbose = false;
                else
                    action.debug.enableVerbose = logical(action.debug.enableVerbose);
                end

                if ~isfield(action.debug,'printSlot')
                    action.debug.printSlot = 0;
                else
                    ps = round(action.debug.printSlot);
                    if ps < 0, ps = 0; end
                    action.debug.printSlot = ps;
                end
            end

            %% ===============================
            % Reserved
            %% ===============================
            if ~isfield(action,'ext')
                action.ext = struct();
            end
        end
    end
end
