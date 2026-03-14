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

        % ===== drop accounting =====
        lastDropThisSlot

        % ===== NEW: traffic class =====
        trafficClassPerUE           % 0=silent 1=normal 2=heavy
        classNameList               % {"silent","normal","heavy"}

        % per class multipliers for different QoS
        rateMulE_perClass
        rateMulU_perClass
        rateMulM_perClass

        overloadFactor              % global multiplier (mild congestion tuning)
    end

    methods
        function obj = TrafficModel(varargin)
            p = inputParser;
            addParameter(p,'numUE',10);
            addParameter(p,'slotDuration',1e-3);
            addParameter(p,'enableBurst',true);
            addParameter(p,'enableStats',true);

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

            obj.overloadFactor = p.Results.overloadFactor;

            obj.slotNow = 0;

            % =========================
            % Base arrival rates (pkt/s)
            % =========================
            % Keep these moderate. Use overloadFactor to push mild congestion.
            obj.baseRate_embb  = 220;
            obj.baseRate_urllc = 55;
            obj.baseRate_mmtc  = 22;

            % =========================
            % Packet sizes (bits)
            % =========================
            obj.embbPktSizeMean = 4.5e5;
            obj.embbPktSizeStd  = 1.8e5;
            obj.urllcPktSize    = 3e4;
            obj.mmtcPktSize     = 2e3;

            obj.urllcDeadlineBase = 8;
            obj.mmtcDeadlineBase  = 200;

            % =========================
            % Buffer (mild congestion needs finite buffer)
            % =========================
            obj.maxBufferBitsPerUE = 30e6;
            obj.maxPacketsPerUE    = 4000;

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

            % =========================
            % Burst ON/OFF
            % =========================
            obj.onState = true(obj.numUE,3);
            obj.remainCounter=zeros(obj.numUE,3);

            % default mild burst
            obj.meanOnSlot  = [80 40 220];
            obj.meanOffSlot = [35 55 520];

            obj.queues=cell(obj.numUE,1);
            for u=1:obj.numUE
                obj.queues{u}=[];
            end

            obj.stats=obj.initStats();
            obj.lastDebugTrace=struct();

            obj.lastDropThisSlot = obj.makeEmptyDropSummary();
        end

        function obj = step(obj)
            obj.slotNow=obj.slotNow+1;

            obj.lastDropThisSlot = obj.makeEmptyDropSummary();
            obj.lastDropThisSlot.slot = obj.slotNow;

            arrivalCount=zeros(obj.numUE,3);

            for u=1:obj.numUE
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
                    obj=obj.enqueueQoS(u,pkt);
                end

                for k=1:nU
                    dl=obj.urllcDeadlinePerUE(u);
                    pkt=obj.createPacket(u,obj.urllcPktSize,dl,"URLLC");
                    obj=obj.enqueueQoS(u,pkt);
                end

                for k=1:nM
                    pkt=obj.createPacket(u,obj.mmtcPktSize,obj.mmtcDeadlineBase,"mMTC");
                    obj=obj.enqueueQoS(u,pkt);
                end
            end

            obj=obj.writeDebugTrace(arrivalCount);
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
            servedBits=0;
            q=obj.queues{ueId};
            while bits>0 && ~isempty(q)
                take=min(bits,q(1).size);
                q(1).size=q(1).size-take;
                servedBits=servedBits+take;
                bits=bits-take;
                if q(1).size<=0
                    q(1)=[];
                end
            end
            obj.queues{ueId}=q;
        end

        function q=getQueue(obj,ueId)
            q=obj.queues{ueId};
        end
    end

    methods (Access=private)

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
        end

        function obj=writeDebugTrace(obj,arrivalCount)
            tr=struct();
            tr.slot=obj.slotNow;
            tr.arrivalTotal=sum(arrivalCount,1);

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

            % NEW: class stats
            tr.class = struct();
            tr.class.countSilent = sum(obj.trafficClassPerUE==0);
            tr.class.countNormal = sum(obj.trafficClassPerUE==1);
            tr.class.countHeavy  = sum(obj.trafficClassPerUE==2);

            obj.lastDebugTrace=tr;
        end

        function s=initStats(~)
            s=struct();
        end
    end
end