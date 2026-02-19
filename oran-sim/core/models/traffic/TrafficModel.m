classdef TrafficModel
%TRAFFICMODEL v4 (heterogeneous + QoS + unified debug trace)
%
% Compatible API:
%   obj = obj.step()
%   obj = obj.decreaseDeadline()
%   [obj, dropped] = obj.dropExpired()
%   [obj, servedBits] = obj.serve(ueId, bits)
%   q = obj.getQueue(ueId)
%
% New:
%   - debug trace support (write into obj.lastDebugTrace)
%   - optional print controlled by cfg.debug
%   - better buffer observability

    properties
        numUE
        slotDuration

        %% Base rates
        baseRate_embb
        baseRate_urllc
        baseRate_mmtc

        %% Packet sizes
        embbPktSizeMean
        embbPktSizeStd
        urllcPktSize
        mmtcPktSize

        %% Deadlines
        urllcDeadlineBase
        mmtcDeadlineBase

        %% UE heterogeneity
        profileType
        mixWeight
        rateScalePerUE
        embbPktMeanPerUE
        urllcDeadlinePerUE
        urllcRateBoostPerUE
        embbRateBoostPerUE
        mmtcRateBoostPerUE

        %% Burst model
        enableBurst
        onState
        meanOnSlot
        meanOffSlot
        remainCounter

        %% Queue limits
        maxBufferBitsPerUE
        maxPacketsPerUE

        %% Runtime
        slotNow
        queues

        %% Stats
        enableStats
        stats

        %% Debug
        lastDebugTrace
    end

    methods
        function obj = TrafficModel(varargin)

            p = inputParser;
            addParameter(p,'numUE',10);
            addParameter(p,'slotDuration',1e-3);
            addParameter(p,'enableBurst',true);
            addParameter(p,'enableStats',true);
            parse(p,varargin{:});

            obj.numUE        = p.Results.numUE;
            obj.slotDuration = p.Results.slotDuration;
            obj.enableBurst  = p.Results.enableBurst;
            obj.enableStats  = p.Results.enableStats;

            obj.slotNow = 0;

            % -----------------------------
            % Baseline traffic parameters
            % -----------------------------
            obj.baseRate_embb  = 200;
            obj.baseRate_urllc = 50;
            obj.baseRate_mmtc  = 20;

            obj.embbPktSizeMean = 5e5;
            obj.embbPktSizeStd  = 2e5;
            obj.urllcPktSize    = 3e4;
            obj.mmtcPktSize     = 2e3;

            obj.urllcDeadlineBase = 8;
            obj.mmtcDeadlineBase  = 200;

            obj.maxBufferBitsPerUE = 20e6;
            obj.maxPacketsPerUE    = 2000;

            % -----------------------------
            % UE profile assignment
            % -----------------------------
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
            obj.embbPktMeanPerUE = max(1e5,obj.embbPktSizeMean*exp(0.25*randn(obj.numUE,1)));
            obj.urllcDeadlinePerUE = obj.makeDeadlinePerUE();

            obj.urllcRateBoostPerUE = ones(obj.numUE,1);
            obj.embbRateBoostPerUE  = ones(obj.numUE,1);
            obj.mmtcRateBoostPerUE  = ones(obj.numUE,1);

            % profile boosts
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

            % -----------------------------
            % Burst
            % -----------------------------
            obj.onState = true(obj.numUE,3);
            obj.remainCounter=zeros(obj.numUE,3);
            obj.meanOnSlot=[60 30 200];
            obj.meanOffSlot=[40 50 500];

            % -----------------------------
            % Queues
            % -----------------------------
            obj.queues=cell(obj.numUE,1);
            for u=1:obj.numUE
                obj.queues{u}=[];
            end

            obj.stats=obj.initStats();
            obj.lastDebugTrace=struct();
        end

        % ============================================================
        % STEP
        % ============================================================
        function obj = step(obj)

            obj.slotNow=obj.slotNow+1;

            arrivalCount=zeros(obj.numUE,3);

            for u=1:obj.numUE

                w=obj.mixWeight(u,:);

                rateE=obj.baseRate_embb*w(1)*obj.rateScalePerUE(u)*obj.embbRateBoostPerUE(u);
                rateU=obj.baseRate_urllc*w(2)*obj.rateScalePerUE(u)*obj.urllcRateBoostPerUE(u);
                rateM=obj.baseRate_mmtc*w(3)*obj.rateScalePerUE(u)*obj.mmtcRateBoostPerUE(u);

                nE=poissrnd(rateE*obj.slotDuration);
                nU=poissrnd(rateU*obj.slotDuration);
                nM=poissrnd(rateM*obj.slotDuration);

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

        % ============================================================
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

    % ================================================================
    % PRIVATE
    % ================================================================
    methods (Access=private)

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
                return;
            end
            q=[q;pkt];
            obj.queues{ueId}=q;
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

            obj.lastDebugTrace=tr;
        end

        function s=initStats(~)
            s=struct();
        end
    end
end
