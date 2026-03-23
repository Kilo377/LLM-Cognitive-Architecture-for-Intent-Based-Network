%{
Author: Chongyu Bao (zt25108@bristol.ac.uk)
File: TrafficModel.m
Description: Traffic model with explicit drop accounting for overflow and expiry.
Adds UE traffic classes (silent/normal/heavy) and light congestion tuning.
Heavy UE creates mild congestion and makes capacity-oriented scheduling meaningful.
%}

classdef TrafficModel
%TRAFFICMODEL v5.0 (traffic class + mild congestion + drop accounting)
%
% Fix:
%   - enqueue overflow drop is counted
%   - expired drop is counted
%   - expose per-slot drop summary for kernel accumulation
%
% New features:
%   - UE traffic class: silent / normal / heavy
%   - per-class rate multiplier for eMBB/URLLC/mMTC
%   - optional burst ON/OFF per (UE,QoS) stream
%   - mild congestion presets via overloadFactor
%
% New fields:
%   obj.trafficClassPerUE
%   obj.rateMulE_perClass
%   obj.rateMulU_perClass
%   obj.rateMulM_perClass

    properties
        numUE
        slotDuration

        baseRate_embb
        baseRate_urllc
        baseRate_mmtc

        embbPktSizeMean
        embbPktSizeStd
        urllcPktSize
        mmtcPktSize

        urllcDeadlineBase
        mmtcDeadlineBase

        profileType
        mixWeight
        rateScalePerUE
        embbPktMeanPerUE
        urllcDeadlinePerUE
        urllcRateBoostPerUE
        embbRateBoostPerUE
        mmtcRateBoostPerUE

        enableBurst
        onState
        meanOnSlot
        meanOffSlot
        remainCounter

        maxBufferBitsPerUE
        maxPacketsPerUE

        slotNow
        queues

        enableStats
        stats

        lastDebugTrace

        debugCfg

        % ===== drop accounting =====
        lastDropThisSlot

        lastQosStatsThisSlot
        qosTypeList

        % ===== NEW: traffic class =====
        trafficClassPerUE           % 0=silent 1=normal 2=heavy
        classNameList               % {"silent","normal","heavy"}

        % per class multipliers for different QoS
        rateMulE_perClass
        rateMulU_perClass
        rateMulM_perClass

        overloadFactor              % global multiplier (mild congestion tuning)

        % ===== dynamic traffic =====
        dynamics
        baseOverloadFactor
        baseOverloadFactor0
        baseRateMulE_perClass
        baseRateMulU_perClass
        baseRateMulM_perClass
        baseRateMulE_perClass0
        baseRateMulU_perClass0
        baseRateMulM_perClass0
        baseMeanOnSlot
        baseMeanOffSlot
        baseMeanOnSlot0
        baseMeanOffSlot0

        % ===== trend (slow drift) =====
        trend
        trendScaleOverload = 1.0
        trendScaleHeavy = 1.0
        trendScaleBurstOn = 1.0
        trendScaleBurstOff = 1.0
        activeUEMask
        activationOrder
        lastTrend
    end

    methods
        function obj = TrafficModel(varargin)
            p = inputParser;
            addParameter(p,'numUE',10);
            addParameter(p,'slotDuration',1e-3);
            addParameter(p,'enableBurst',true);
            addParameter(p,'enableStats',true);
            addParameter(p,'debugCfg',struct());
            addParameter(p,'dynamicCfg',struct());
            addParameter(p,'trendCfg',struct());

            % NEW knobs
            addParameter(p,'overloadFactor',1.25);      % >1 makes system slightly congested
            addParameter(p,'silentRatio',0.15);         % UE fraction
            addParameter(p,'heavyRatio',0.20);          % UE fraction
            addParameter(p,'heavyMultiplierE',6.0);     % heavy eMBB multiplier
            addParameter(p,'heavyMultiplierU',2.5);     % heavy URLLC multiplier
            addParameter(p,'heavyMultiplierM',3.0);     % heavy mMTC multiplier
            addParameter(p,'silentMultiplier',0.10);    % silent multiplier for all QoS
            parse(p,varargin{:});

            obj.numUE        = p.Results.numUE;
            obj.slotDuration = p.Results.slotDuration;
            obj.enableBurst  = p.Results.enableBurst;
            obj.enableStats  = p.Results.enableStats;
            obj.debugCfg     = p.Results.debugCfg;

            obj.overloadFactor = p.Results.overloadFactor;
            obj.baseOverloadFactor0 = obj.overloadFactor;
            obj.baseOverloadFactor = obj.overloadFactor;

            obj.slotNow = 0;

            % =========================
            % Base arrival rates (pkt/s)
            % =========================
            % Keep these moderate. Use overloadFactor to push mild congestion.
            obj.baseRate_embb  = 260;
            obj.baseRate_urllc = 70;
            obj.baseRate_mmtc  = 30;

            % =========================
            % Packet sizes (bits)
            % =========================
            obj.embbPktSizeMean = 4.5e5;
            obj.embbPktSizeStd  = 1.8e5;
            obj.urllcPktSize    = 3e4;
            obj.mmtcPktSize     = 2e3;

            obj.urllcDeadlineBase = 6;
            obj.mmtcDeadlineBase  = 120;

            % =========================
            % Buffer (mild congestion needs finite buffer)
            % =========================
            obj.maxBufferBitsPerUE = 15e6;
            obj.maxPacketsPerUE    = 2200;

            % =========================
            % Profile types
            % =========================
            obj.profileType = repmat("Mixed", obj.numUE,1);
            idx = randperm(obj.numUE);

            nE = round(obj.numUE*0.35);
            nU = round(obj.numUE*0.20);
            nM = round(obj.numUE*0.15);

            if nE>0, obj.profileType(idx(1:nE))="eMBB"; end
            if nU>0, obj.profileType(idx(nE+1:nE+nU))="URLLC"; end
            if nM>0, obj.profileType(idx(nE+nU+1:nE+nU+nM))="mMTC"; end

            obj.mixWeight = zeros(obj.numUE,3);
            obj = obj.refreshMixWeight();

            obj.rateScalePerUE   = exp(0.35*randn(obj.numUE,1));
            obj.embbPktMeanPerUE = max(8e4, obj.embbPktSizeMean*exp(0.25*randn(obj.numUE,1)));
            obj.urllcDeadlinePerUE = obj.makeDeadlinePerUE();

            obj.urllcRateBoostPerUE = ones(obj.numUE,1);
            obj.embbRateBoostPerUE  = ones(obj.numUE,1);
            obj.mmtcRateBoostPerUE  = ones(obj.numUE,1);

            for u=1:obj.numUE
                t=obj.profileType(u);
                if t=="URLLC"
                    obj.urllcRateBoostPerUE(u)=2.5;
                elseif t=="eMBB"
                    obj.embbRateBoostPerUE(u)=2.0;
                elseif t=="mMTC"
                    obj.mmtcRateBoostPerUE(u)=3.0;
                end
            end

            % =========================
            % NEW: traffic class assignment
            % =========================
            obj.classNameList = ["silent","normal","heavy"];

            silentRatio = max(0,min(0.8,p.Results.silentRatio));
            heavyRatio  = max(0,min(0.8,p.Results.heavyRatio));
            normalRatio = max(0, 1 - silentRatio - heavyRatio);

            if normalRatio < 0
                normalRatio = 0.0;
                s = silentRatio + heavyRatio;
                silentRatio = silentRatio / s;
                heavyRatio  = heavyRatio  / s;
            end

            obj.trafficClassPerUE = ones(obj.numUE,1); % normal
            r = rand(obj.numUE,1);
            obj.trafficClassPerUE(r < silentRatio) = 0;
            obj.trafficClassPerUE(r >= (1-heavyRatio)) = 2;

            % class multipliers (index: class+1)
            silentMul = p.Results.silentMultiplier;
            heavyMulE = p.Results.heavyMultiplierE;
            heavyMulU = p.Results.heavyMultiplierU;
            heavyMulM = p.Results.heavyMultiplierM;

            obj.rateMulE_perClass = [silentMul, 1.0, heavyMulE];
            obj.rateMulU_perClass = [silentMul, 1.0, heavyMulU];
            obj.rateMulM_perClass = [silentMul, 1.0, heavyMulM];

            obj.baseRateMulE_perClass = obj.rateMulE_perClass;
            obj.baseRateMulU_perClass = obj.rateMulU_perClass;
            obj.baseRateMulM_perClass = obj.rateMulM_perClass;

            obj.baseRateMulE_perClass0 = obj.rateMulE_perClass;
            obj.baseRateMulU_perClass0 = obj.rateMulU_perClass;
            obj.baseRateMulM_perClass0 = obj.rateMulM_perClass;

            % =========================
            % Burst ON/OFF
            % =========================
            obj.onState = true(obj.numUE,3);
            obj.remainCounter=zeros(obj.numUE,3);

            % default mild burst
            obj.meanOnSlot  = [80 40 220];
            obj.meanOffSlot = [35 55 520];

            obj.baseMeanOnSlot  = obj.meanOnSlot;
            obj.baseMeanOffSlot = obj.meanOffSlot;

            obj.baseMeanOnSlot0  = obj.meanOnSlot;
            obj.baseMeanOffSlot0 = obj.meanOffSlot;

            obj.queues=cell(obj.numUE,1);
            for u=1:obj.numUE
                obj.queues{u}=[];
            end

            obj.stats=obj.initStats();
            obj.lastDebugTrace=struct();

            obj.lastDropThisSlot = obj.makeEmptyDropSummary();
            obj.qosTypeList = ["eMBB","URLLC","mMTC"];
            obj.lastQosStatsThisSlot = obj.makeEmptyQosStats();

            obj.activationOrder = randperm(obj.numUE);
            obj.activeUEMask = true(obj.numUE,1);

            dynCfg = p.Results.dynamicCfg;
            if isstruct(dynCfg) && isfield(dynCfg,'enable') && dynCfg.enable
                if ~isfield(dynCfg,'profiles')
                    obj.dynamics = TrafficDynamics(dynCfg);
                else
                    try
                        ps = string(dynCfg.profiles);
                        if any(ps == "traffic")
                            obj.dynamics = TrafficDynamics(dynCfg);
                        end
                    catch
                    end
                end
            end

            trendCfg = p.Results.trendCfg;
            if isstruct(trendCfg) && isfield(trendCfg,'enable') && trendCfg.enable
                obj.trend = TrafficTrend(trendCfg);
            end
        end

        function obj = setProfileRatio(obj, ratio)

            if isempty(ratio) || ~isstruct(ratio)
                return;
            end

            rE = 0; rU = 0; rM = 0; rX = 0;
            if isfield(ratio,'eMBB'), rE = max(0, ratio.eMBB); end
            if isfield(ratio,'URLLC'), rU = max(0, ratio.URLLC); end
            if isfield(ratio,'mMTC'), rM = max(0, ratio.mMTC); end
            if isfield(ratio,'Mixed'), rX = max(0, ratio.Mixed); end

            s = rE + rU + rM + rX;
            if s <= 0
                return;
            end
            if s > 1
                rE = rE / s;
                rU = rU / s;
                rM = rM / s;
                rX = rX / s;
            end

            rem = max(0, 1 - (rE + rU + rM + rX));
            rX = rX + rem;

            nE = round(obj.numUE * rE);
            nU = round(obj.numUE * rU);
            nM = round(obj.numUE * rM);
            nX = max(0, obj.numUE - nE - nU - nM);

            idx = randperm(obj.numUE);
            obj.profileType = repmat("Mixed", obj.numUE,1);

            if nE > 0
                obj.profileType(idx(1:nE)) = "eMBB";
            end
            if nU > 0
                obj.profileType(idx(nE+1:nE+nU)) = "URLLC";
            end
            if nM > 0
                obj.profileType(idx(nE+nU+1:nE+nU+nM)) = "mMTC";
            end
            if nX > 0
                obj.profileType(idx(nE+nU+nM+1:end)) = "Mixed";
            end

            obj = obj.refreshMixWeight();
            obj = obj.refreshRateBoosts();
        end

        function obj = step(obj)
            obj.slotNow=obj.slotNow+1;

            obj = obj.applyTrend();

            obj = obj.applyDynamics();

            obj.lastDropThisSlot = obj.makeEmptyDropSummary();
            obj.lastDropThisSlot.slot = obj.slotNow;

            obj.lastQosStatsThisSlot = obj.makeEmptyQosStats();
            obj.lastQosStatsThisSlot.slot = obj.slotNow;

            arrivalCount=zeros(obj.numUE,3);

            for u=1:obj.numUE
                if ~isempty(obj.activeUEMask) && ~obj.activeUEMask(u)
                    continue;
                end
                w=obj.mixWeight(u,:);

                % base rates
                rateE=obj.baseRate_embb*w(1)*obj.rateScalePerUE(u)*obj.embbRateBoostPerUE(u);
                rateU=obj.baseRate_urllc*w(2)*obj.rateScalePerUE(u)*obj.urllcRateBoostPerUE(u);
                rateM=obj.baseRate_mmtc*w(3)*obj.rateScalePerUE(u)*obj.mmtcRateBoostPerUE(u);

                % NEW: traffic class multiplier
                cls = obj.trafficClassPerUE(u); % 0/1/2
                rateE = rateE * obj.rateMulE_perClass(cls+1);
                rateU = rateU * obj.rateMulU_perClass(cls+1);
                rateM = rateM * obj.rateMulM_perClass(cls+1);

                % NEW: mild congestion tuning
                rateE = rateE * obj.overloadFactor;
                rateU = rateU * obj.overloadFactor;
                rateM = rateM * obj.overloadFactor;

                % optional burst gating
                if obj.enableBurst
                    [obj, gE] = obj.burstGate(u,1);
                    [obj, gU] = obj.burstGate(u,2);
                    [obj, gM] = obj.burstGate(u,3);
                else
                    gE=1; gU=1; gM=1;
                end

                nE=poissrnd(max(0,rateE*gE)*obj.slotDuration);
                nU=poissrnd(max(0,rateU*gU)*obj.slotDuration);
                nM=poissrnd(max(0,rateM*gM)*obj.slotDuration);

                arrivalCount(u,:)=[nE nU nM];

                for k=1:nE
                    sz=max(1e4,obj.embbPktMeanPerUE(u)+obj.embbPktSizeStd*randn());
                    pkt=obj.createPacket(u,sz,inf,"eMBB");
                    obj = obj.countQosArrival(pkt);
                    obj=obj.enqueueQoS(u,pkt);
                end

                for k=1:nU
                    dl=obj.urllcDeadlinePerUE(u);
                    pkt=obj.createPacket(u,obj.urllcPktSize,dl,"URLLC");
                    obj = obj.countQosArrival(pkt);
                    obj=obj.enqueueQoS(u,pkt);
                end

                for k=1:nM
                    pkt=obj.createPacket(u,obj.mmtcPktSize,obj.mmtcDeadlineBase,"mMTC");
                    obj = obj.countQosArrival(pkt);
                    obj=obj.enqueueQoS(u,pkt);
                end
            end

            obj=obj.writeDebugTrace(arrivalCount);

            if obj.shouldPrintDebug()
                obj.printDebug();
            end
        end

        function obj = decreaseDeadline(obj)
            for u=1:obj.numUE
                q=obj.queues{u};
                for i=1:numel(q)
                    q(i).age=q(i).age+1;
                    if isfinite(q(i).deadline)
                        q(i).deadline=q(i).deadline-1;
                    end
                end
                obj.queues{u}=q;
            end
        end

        function [obj,dropped]=dropExpired(obj)
            dropped=[];
            for u=1:obj.numUE
                q=obj.queues{u};
                expired=arrayfun(@(p)isfinite(p.deadline)&&p.deadline<=0,q);
                if any(expired)
                    dropPkts=q(expired);
                    dropped=[dropped;dropPkts(:)];
                    q=q(~expired);
                    obj.queues{u}=q;

                    obj = obj.countDroppedPkts(dropPkts, "expired");
                end
            end
        end

        function [obj,servedBits]=serve(obj,ueId,bits)
            [obj, servedBits] = obj.serveWithPriority(ueId, bits, []);
        end

        function [obj,servedBits,servedQosBits]=serveWithPriority(obj,ueId,bits,qosPriority)
            servedBits=0;
            servedQosBits = zeros(3,1);
            q=obj.queues{ueId};

            if isempty(q)
                return;
            end

            if nargin >= 4 && ~isempty(qosPriority)
                q = obj.sortQueueByPriority(q, qosPriority);
            end

            while bits>0 && ~isempty(q)
                take=min(bits,q(1).size);
                q(1).size=q(1).size-take;
                servedBits=servedBits+take;
                bits=bits-take;

                idx = obj.qosTypeToIndex(q(1).type);
                servedQosBits(idx) = servedQosBits(idx) + take;
                obj = obj.countQosServed(q(1).type, take);

                if q(1).size<=0
                    q(1)=[];
                end
            end
            obj.queues{ueId}=q;
        end

        function q=getQueue(obj,ueId)
            q=obj.queues{ueId};
        end

        function s = getQosStats(obj)
            s = obj.lastQosStatsThisSlot;
        end
    end

    methods (Access=private)

        function obj = applyDynamics(obj)
            if isempty(obj.dynamics)
                return;
            end

            dyn = obj.dynamics.get(obj.slotNow);

            obj.overloadFactor = obj.baseOverloadFactor * dyn.overloadScale;

            obj.rateMulE_perClass = obj.baseRateMulE_perClass;
            obj.rateMulU_perClass = obj.baseRateMulU_perClass;
            obj.rateMulM_perClass = obj.baseRateMulM_perClass;

            obj.rateMulE_perClass(1) = obj.baseRateMulE_perClass(1) * dyn.silentMulScale;
            obj.rateMulU_perClass(1) = obj.baseRateMulU_perClass(1) * dyn.silentMulScale;
            obj.rateMulM_perClass(1) = obj.baseRateMulM_perClass(1) * dyn.silentMulScale;

            obj.rateMulE_perClass(3) = obj.baseRateMulE_perClass(3) * dyn.heavyMulScale;
            obj.rateMulU_perClass(3) = obj.baseRateMulU_perClass(3) * dyn.heavyMulScale;
            obj.rateMulM_perClass(3) = obj.baseRateMulM_perClass(3) * dyn.heavyMulScale;

            onScale = dyn.burstScale;
            offScale = 1 / max(dyn.burstScale, 0.2);
            obj.meanOnSlot  = max(1, obj.baseMeanOnSlot * onScale);
            obj.meanOffSlot = max(1, obj.baseMeanOffSlot * offScale);
        end

        function obj = applyTrend(obj)
            if isempty(obj.trend)
                obj.baseOverloadFactor = obj.baseOverloadFactor0;
                obj.baseRateMulE_perClass = obj.baseRateMulE_perClass0;
                obj.baseRateMulU_perClass = obj.baseRateMulU_perClass0;
                obj.baseRateMulM_perClass = obj.baseRateMulM_perClass0;
                obj.baseMeanOnSlot = obj.baseMeanOnSlot0;
                obj.baseMeanOffSlot = obj.baseMeanOffSlot0;
                return;
            end

            tr = obj.trend.get(obj.slotNow);
            obj.lastTrend = tr;

            obj.trendScaleOverload = tr.overloadScale;
            obj.trendScaleHeavy = tr.heavyMulScale;
            obj.trendScaleBurstOn = tr.burstOnScale;
            obj.trendScaleBurstOff = tr.burstOffScale;

            obj.baseOverloadFactor = obj.baseOverloadFactor0 * obj.trendScaleOverload;

            obj.baseRateMulE_perClass = obj.baseRateMulE_perClass0;
            obj.baseRateMulU_perClass = obj.baseRateMulU_perClass0;
            obj.baseRateMulM_perClass = obj.baseRateMulM_perClass0;

            obj.baseRateMulE_perClass(3) = obj.baseRateMulE_perClass0(3) * obj.trendScaleHeavy;
            obj.baseRateMulU_perClass(3) = obj.baseRateMulU_perClass0(3) * obj.trendScaleHeavy;
            obj.baseRateMulM_perClass(3) = obj.baseRateMulM_perClass0(3) * obj.trendScaleHeavy;

            obj.baseMeanOnSlot  = max(1, obj.baseMeanOnSlot0 * obj.trendScaleBurstOn);
            obj.baseMeanOffSlot = max(1, obj.baseMeanOffSlot0 * obj.trendScaleBurstOff);

            activeRatio = tr.activeRatio;
            activeCount = max(1, round(obj.numUE * activeRatio));
            activeCount = min(activeCount, obj.numUE);

            mask = false(obj.numUE,1);
            if isempty(obj.activationOrder)
                obj.activationOrder = randperm(obj.numUE);
            end
            mask(obj.activationOrder(1:activeCount)) = true;
            obj.activeUEMask = mask;
        end

        function obj = refreshRateBoosts(obj)
            obj.urllcRateBoostPerUE = ones(obj.numUE,1);
            obj.embbRateBoostPerUE  = ones(obj.numUE,1);
            obj.mmtcRateBoostPerUE  = ones(obj.numUE,1);

            for u=1:obj.numUE
                t=obj.profileType(u);
                if t=="URLLC"
                    obj.urllcRateBoostPerUE(u)=2.5;
                elseif t=="eMBB"
                    obj.embbRateBoostPerUE(u)=2.0;
                elseif t=="mMTC"
                    obj.mmtcRateBoostPerUE(u)=3.0;
                end
            end
        end

        function [obj, gate] = burstGate(obj, u, streamIdx)
            gate = 1;
            if obj.remainCounter(u,streamIdx) <= 0
                if obj.onState(u,streamIdx)
                    obj.onState(u,streamIdx) = false;
                    obj.remainCounter(u,streamIdx) = max(1, round(exprnd(obj.meanOffSlot(streamIdx))));
                else
                    obj.onState(u,streamIdx) = true;
                    obj.remainCounter(u,streamIdx) = max(1, round(exprnd(obj.meanOnSlot(streamIdx))));
                end
            end
            obj.remainCounter(u,streamIdx) = obj.remainCounter(u,streamIdx) - 1;
            if ~obj.onState(u,streamIdx)
                gate = 0;
            end
        end

        function s = makeEmptyDropSummary(~)
            s = struct( ...
                'slot',0, ...
                'countTotal',0,'bitsTotal',0, ...
                'countURLLC',0,'bitsURLLC',0, ...
                'countOverflow',0,'bitsOverflow',0, ...
                'countExpired',0,'bitsExpired',0 );
        end

        function s = makeEmptyQosStats(~)
            s = struct();
            s.slot = 0;
            s.arrivedBits = zeros(3,1);
            s.servedBits  = zeros(3,1);
            s.droppedBits = zeros(3,1);
            s.droppedCount = zeros(3,1);
        end

        function obj=refreshMixWeight(obj)
            for u=1:obj.numUE
                t=obj.profileType(u);
                if t=="eMBB"
                    obj.mixWeight(u,:)=[0.9 0.08 0.02];
                elseif t=="URLLC"
                    obj.mixWeight(u,:)=[0.1 0.85 0.05];
                elseif t=="mMTC"
                    obj.mixWeight(u,:)=[0.1 0.05 0.85];
                else
                    obj.mixWeight(u,:)=[0.6 0.3 0.1];
                end
            end
        end

        function dl=makeDeadlinePerUE(obj)
            dl=obj.urllcDeadlineBase*ones(obj.numUE,1);
            dl=max(2,dl+randi([-1 1],obj.numUE,1));
        end

        function pkt=createPacket(obj,ueId,sizeBits,deadlineSlots,typeStr)
            pkt.size=sizeBits;
            pkt.deadline=deadlineSlots;
            pkt.type=typeStr;
            pkt.age=0;
            pkt.ueId=ueId;
            pkt.t0_slot=obj.slotNow;
        end

        function obj=enqueueQoS(obj,ueId,pkt)
            q=obj.queues{ueId};

            if numel(q)>=obj.maxPacketsPerUE
                obj = obj.countDroppedPkts(pkt, "overflow");
                return;
            end

            curBits = 0;
            if ~isempty(q)
                curBits = sum([q.size]);
            end
            if curBits + pkt.size > obj.maxBufferBitsPerUE
                obj = obj.countDroppedPkts(pkt, "overflow");
                return;
            end

            q=[q;pkt];
            obj.queues{ueId}=q;
        end

        function obj = countDroppedPkts(obj, pkts, reason)
            if isempty(pkts)
                return;
            end

            bits = sum([pkts.size]);
            cnt  = numel(pkts);

            obj.lastDropThisSlot.countTotal = obj.lastDropThisSlot.countTotal + cnt;
            obj.lastDropThisSlot.bitsTotal  = obj.lastDropThisSlot.bitsTotal + bits;

            isU = arrayfun(@(p) (string(p.type)=="URLLC"), pkts);
            if any(isU)
                obj.lastDropThisSlot.countURLLC = obj.lastDropThisSlot.countURLLC + sum(isU);
                obj.lastDropThisSlot.bitsURLLC  = obj.lastDropThisSlot.bitsURLLC  + sum([pkts(isU).size]);
            end

            if reason=="overflow"
                obj.lastDropThisSlot.countOverflow = obj.lastDropThisSlot.countOverflow + cnt;
                obj.lastDropThisSlot.bitsOverflow  = obj.lastDropThisSlot.bitsOverflow  + bits;
            end
            if reason=="expired"
                obj.lastDropThisSlot.countExpired = obj.lastDropThisSlot.countExpired + cnt;
                obj.lastDropThisSlot.bitsExpired  = obj.lastDropThisSlot.bitsExpired  + bits;
            end

            for i = 1:numel(pkts)
                obj = obj.countQosDrop(pkts(i));
            end
        end

        function obj = countQosArrival(obj, pkt)
            idx = obj.qosTypeToIndex(pkt.type);
            obj.lastQosStatsThisSlot.arrivedBits(idx) = ...
                obj.lastQosStatsThisSlot.arrivedBits(idx) + pkt.size;
        end

        function obj = countQosDrop(obj, pkt)
            idx = obj.qosTypeToIndex(pkt.type);
            obj.lastQosStatsThisSlot.droppedBits(idx) = ...
                obj.lastQosStatsThisSlot.droppedBits(idx) + pkt.size;
            obj.lastQosStatsThisSlot.droppedCount(idx) = ...
                obj.lastQosStatsThisSlot.droppedCount(idx) + 1;
        end

        function obj = countQosServed(obj, typeStr, bits)
            idx = obj.qosTypeToIndex(typeStr);
            obj.lastQosStatsThisSlot.servedBits(idx) = ...
                obj.lastQosStatsThisSlot.servedBits(idx) + bits;
        end

        function idx = qosTypeToIndex(obj, typeStr)
            t = string(typeStr);
            if t == "URLLC"
                idx = 2;
            elseif t == "mMTC"
                idx = 3;
            else
                idx = 1;
            end
        end

        function q = sortQueueByPriority(~, q, qosPriority)
            if isempty(q)
                return;
            end

            wE = qosPriority.eMBB;
            wU = qosPriority.URLLC;
            wM = qosPriority.mMTC;

            weights = zeros(numel(q),1);
            deadlines = zeros(numel(q),1);
            ages = zeros(numel(q),1);

            for i = 1:numel(q)
                t = string(q(i).type);
                if t == "URLLC"
                    weights(i) = wU;
                elseif t == "mMTC"
                    weights(i) = wM;
                else
                    weights(i) = wE;
                end

                d = q(i).deadline;
                if ~isfinite(d)
                    d = 1e9;
                end
                deadlines(i) = d;
                ages(i) = q(i).age;
            end

            keys = [-weights, deadlines, -ages];
            [~, idx] = sortrows(keys, [1 2 3]);
            q = q(idx);
        end

        function obj=writeDebugTrace(obj,arrivalCount)
            tr=struct();
            tr.slot=obj.slotNow;
            tr.arrivalTotal=sum(arrivalCount,1);

            tr.activeUECount = sum(obj.activeUEMask);
            if ~isempty(obj.lastTrend)
                tr.trend = obj.lastTrend;
            end

            tr.dynamic = struct();
            tr.dynamic.overloadFactor = obj.overloadFactor;
            tr.dynamic.heavyMulE = obj.rateMulE_perClass(3);
            tr.dynamic.heavyMulU = obj.rateMulU_perClass(3);
            tr.dynamic.heavyMulM = obj.rateMulM_perClass(3);
            tr.dynamic.silentMulE = obj.rateMulE_perClass(1);
            tr.dynamic.silentMulU = obj.rateMulU_perClass(1);
            tr.dynamic.silentMulM = obj.rateMulM_perClass(1);
            tr.dynamic.burstOn = obj.meanOnSlot;
            tr.dynamic.burstOff = obj.meanOffSlot;

            tr.queueBits=zeros(obj.numUE,1);
            tr.queueLen=zeros(obj.numUE,1);

            for u=1:obj.numUE
                q=obj.queues{u};
                if ~isempty(q)
                    tr.queueBits(u)=sum([q.size]);
                    tr.queueLen(u)=numel(q);
                end
            end

            tr.dropThisSlot = obj.lastDropThisSlot;
            tr.qosThisSlot = obj.lastQosStatsThisSlot;

            % NEW: class stats
            tr.class = struct();
            tr.class.countSilent = sum(obj.trafficClassPerUE==0);
            tr.class.countNormal = sum(obj.trafficClassPerUE==1);
            tr.class.countHeavy  = sum(obj.trafficClassPerUE==2);

            obj.lastDebugTrace=tr;
        end

        function tf = shouldPrintDebug(obj)
            tf = false;

            if isempty(obj.lastDebugTrace)
                return;
            end

            cfg = obj.debugCfg;
            if isempty(cfg) || ~isstruct(cfg)
                return;
            end

            if ~isfield(cfg,'enable') || ~cfg.enable
                return;
            end

            every = 1;
            if isfield(cfg,'every') && isnumeric(cfg.every) && cfg.every >= 1
                every = round(cfg.every);
            end
            if mod(obj.slotNow, every) ~= 0
                return;
            end

            if isfield(cfg,'modules')
                try
                    ms = string(cfg.modules);
                    if ~any(ms=="traffic") && ~any(ms=="all")
                        return;
                    end
                catch
                end
            end

            tf = true;
        end

        function printDebug(obj)
            tr = obj.lastDebugTrace;
            if isempty(tr) || ~isfield(tr,'slot')
                return;
            end
            fprintf('[DEBUG][slot=%d][traffic] arrived=[%.0f %.0f %.0f] queueBits=%.0f queueLen=%.0f\n', ...
                tr.slot, tr.arrivalTotal(1), tr.arrivalTotal(2), tr.arrivalTotal(3), ...
                sum(tr.queueBits), sum(tr.queueLen));
            if isfield(tr,'activeUECount')
                fprintf('  trend: activeUE=%d/%d\n', tr.activeUECount, obj.numUE);
            end
            if isfield(tr,'trend')
                tf = tr.trend.factor;
                fprintf('  trend: factor=%.2f overloadScale=%.2f heavyMulScale=%.2f\n', ...
                    tf, tr.trend.overloadScale, tr.trend.heavyMulScale);
            end
            if isfield(tr,'dynamic')
                d = tr.dynamic;
                fprintf('  dyn: overload=%.2f heavyMul=[%.2f %.2f %.2f] silentMul=[%.2f %.2f %.2f]\n', ...
                    d.overloadFactor, d.heavyMulE, d.heavyMulU, d.heavyMulM, ...
                    d.silentMulE, d.silentMulU, d.silentMulM);
                fprintf('  dyn: burstOn=%s burstOff=%s\n', mat2str(d.burstOn), mat2str(d.burstOff));
            end
        end

        function s=initStats(~)
            s=struct();
        end
    end
end
