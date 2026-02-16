classdef TrafficModel
%TRAFFICMODEL v3: UE-heterogeneous multi-service traffic with QoS-aware drops
%
% Compatible API:
%   obj = obj.step()
%   obj = obj.decreaseDeadline()
%   [obj, dropped] = obj.dropExpired()
%   [obj, servedBits] = obj.serve(ueId, bits)
%   q = obj.getQueue(ueId)
%
% Packet fields:
%   .size      (bits)
%   .deadline  (slots) (inf for eMBB)
%   .type      ('eMBB'/'URLLC'/'mMTC')
%   .age       (slots)
%   .ueId
%   .t0_slot

    properties
        numUE
        slotDuration

        %% ===== Base rates (pkts/sec) for a "unit" UE =====
        baseRate_embb
        baseRate_urllc
        baseRate_mmtc

        %% ===== Base packet sizes (bits) =====
        embbPktSizeMean
        embbPktSizeStd
        urllcPktSize
        mmtcPktSize

        %% ===== Base deadlines (slots) =====
        urllcDeadlineBase
        mmtcDeadlineBase

        %% ===== UE heterogeneity =====
        profileType              % [numUE x 1] string: "eMBB"/"URLLC"/"mMTC"/"Mixed"
        mixWeight                % [numUE x 3] weights [eMBB URLLC mMTC], normalized

        rateScalePerUE           % [numUE x 1] scale factor for all rates
        embbPktMeanPerUE         % [numUE x 1]
        urllcDeadlinePerUE       % [numUE x 1] slots
        urllcRateBoostPerUE      % [numUE x 1] extra multiplier for URLLC-heavy
        embbRateBoostPerUE       % [numUE x 1]
        mmtcRateBoostPerUE       % [numUE x 1]

        %% ===== Burstiness =====
        enableBurst
        onState                  % [numUE x 3] logical
        meanOnSlot               % [1 x 3] mean ON duration in slots
        meanOffSlot              % [1 x 3] mean OFF duration in slots
        remainCounter            % [numUE x 3] remaining slots in current ON/OFF state

        %% ===== Queue constraints =====
        maxBufferBitsPerUE
        maxPacketsPerUE

        %% ===== Runtime =====
        slotNow
        queues                   % cell {numUE} of packet arrays

        %% ===== Stats (optional) =====
        enableStats
        stats
    end

    methods
        function obj = TrafficModel(varargin)

            p = inputParser;
            addParameter(p, 'numUE', 10);
            addParameter(p, 'slotDuration', 1e-3);
            addParameter(p, 'enableBurst', true);
            addParameter(p, 'enableStats', true);

            % profile ratios
            addParameter(p, 'ratio_eMBB', 0.35);
            addParameter(p, 'ratio_URLLC', 0.20);
            addParameter(p, 'ratio_mMTC', 0.15);
            % remaining -> Mixed

            parse(p, varargin{:});

            obj.numUE        = p.Results.numUE;
            obj.slotDuration = p.Results.slotDuration;
            obj.enableBurst  = p.Results.enableBurst;
            obj.enableStats  = p.Results.enableStats;

            obj.slotNow = 0;

            %% ===== Baselines (you can tune later) =====
            obj.baseRate_embb  = 200;
            obj.baseRate_urllc = 50;
            obj.baseRate_mmtc  = 20;

            obj.embbPktSizeMean = 5e5;
            obj.embbPktSizeStd  = 2e5;
            obj.urllcPktSize    = 3e4;
            obj.mmtcPktSize     = 2e3;

            obj.urllcDeadlineBase = 8;
            obj.mmtcDeadlineBase  = 200;

            %% ===== Queue limits =====
            obj.maxBufferBitsPerUE = 20e6;
            obj.maxPacketsPerUE    = 2000;

            %% ===== UE profile assignment =====
            obj.profileType = repmat("Mixed", obj.numUE, 1);

            nE = round(obj.numUE * p.Results.ratio_eMBB);
            nU = round(obj.numUE * p.Results.ratio_URLLC);
            nM = round(obj.numUE * p.Results.ratio_mMTC);
            nX = obj.numUE - nE - nU - nM; %#ok<NASGU>

            idx = randperm(obj.numUE);
            i1 = 1;
            i2 = i1 + nE - 1;
            i3 = i2 + nU;
            i4 = i3 + nM;

            if nE > 0, obj.profileType(idx(i1:i2)) = "eMBB"; end
            if nU > 0, obj.profileType(idx(i2+1:i3)) = "URLLC"; end
            if nM > 0, obj.profileType(idx(i3+1:i4)) = "mMTC"; end
            % rest are Mixed

            obj.mixWeight = zeros(obj.numUE, 3);
            obj = obj.refreshMixWeightFromProfile();

            %% ===== UE-parameter heterogeneity =====
            obj.rateScalePerUE      = obj.logNormalScale(obj.numUE, 0.0, 0.35); % mean~1, moderate spread
            obj.embbPktMeanPerUE    = max(1e5, obj.embbPktSizeMean .* obj.logNormalScale(obj.numUE, 0.0, 0.25));
            obj.urllcDeadlinePerUE  = obj.makeDeadlinePerUE();

            obj.urllcRateBoostPerUE = ones(obj.numUE,1);
            obj.embbRateBoostPerUE  = ones(obj.numUE,1);
            obj.mmtcRateBoostPerUE  = ones(obj.numUE,1);

            % Boost per profile (creates stable preference for xApps)
            for u = 1:obj.numUE
                t = obj.profileType(u);
                if t == "URLLC"
                    obj.urllcRateBoostPerUE(u) = 2.5;
                    obj.embbRateBoostPerUE(u)  = 0.7;
                elseif t == "eMBB"
                    obj.embbRateBoostPerUE(u)  = 2.0;
                    obj.urllcRateBoostPerUE(u) = 0.7;
                elseif t == "mMTC"
                    obj.mmtcRateBoostPerUE(u)  = 3.0;
                    obj.embbRateBoostPerUE(u)  = 0.6;
                end
            end

            %% ===== Burst model =====
            obj.onState       = true(obj.numUE, 3);
            obj.remainCounter = zeros(obj.numUE, 3);

            % mean ON/OFF durations in slots (service-wise)
            obj.meanOnSlot  = [60  30  200];  % eMBB less bursty, URLLC more spiky, mMTC long idle/active
            obj.meanOffSlot = [40  50  500];

            if obj.enableBurst
                % initialize counters
                for u = 1:obj.numUE
                    for k = 1:3
                        obj.onState(u,k) = (rand < 0.7);
                        if obj.onState(u,k)
                            obj.remainCounter(u,k) = obj.sampleGeomSlots(obj.meanOnSlot(k));
                        else
                            obj.remainCounter(u,k) = obj.sampleGeomSlots(obj.meanOffSlot(k));
                        end
                    end
                end
            end

            %% ===== Queues =====
            obj.queues = cell(obj.numUE, 1);
            for u = 1:obj.numUE
                obj.queues{u} = [];
            end

            %% ===== Stats =====
            obj.stats = obj.initStats();
        end

        function obj = step(obj)
            %STEP Generate arrivals for all UEs

            obj.slotNow = obj.slotNow + 1;

            for u = 1:obj.numUE

                if obj.enableBurst
                    obj = obj.advanceBurst(u);
                end

                w = obj.mixWeight(u,:);

                % Base rates scaled by profile mix and UE scale
                rateE = obj.baseRate_embb  * w(1) * obj.rateScalePerUE(u) * obj.embbRateBoostPerUE(u);
                rateU = obj.baseRate_urllc * w(2) * obj.rateScalePerUE(u) * obj.urllcRateBoostPerUE(u);
                rateM = obj.baseRate_mmtc  * w(3) * obj.rateScalePerUE(u) * obj.mmtcRateBoostPerUE(u);

                % Burst gating (multiplicative)
                if obj.enableBurst
                    if ~obj.onState(u,1), rateE = rateE * 0.05; end
                    if ~obj.onState(u,2), rateU = rateU * 0.10; end
                    if ~obj.onState(u,3), rateM = rateM * 0.05; end
                end

                % Poisson arrivals per slot
                nE = obj.poissonCount(rateE * obj.slotDuration);
                nU = obj.poissonCount(rateU * obj.slotDuration);
                nM = obj.poissonCount(rateM * obj.slotDuration);

                for k = 1:nE
                    sz = max(1e4, obj.embbPktMeanPerUE(u) + obj.embbPktSizeStd*randn());
                    pkt = obj.createPacket(u, sz, inf, 'eMBB');
                    obj = obj.enqueueQoS(u, pkt);
                end

                for k = 1:nU
                    dl = obj.urllcDeadlinePerUE(u);
                    pkt = obj.createPacket(u, obj.urllcPktSize, dl, 'URLLC');
                    obj = obj.enqueueQoS(u, pkt);
                end

                for k = 1:nM
                    pkt = obj.createPacket(u, obj.mmtcPktSize, obj.mmtcDeadlineBase, 'mMTC');
                    obj = obj.enqueueQoS(u, pkt);
                end
            end
        end

        function obj = decreaseDeadline(obj)
            for u = 1:obj.numUE
                q = obj.queues{u};
                if isempty(q), continue; end

                for i = 1:numel(q)
                    q(i).age = q(i).age + 1;
                    if isfinite(q(i).deadline)
                        q(i).deadline = q(i).deadline - 1;
                    end
                end
                obj.queues{u} = q;
            end
        end

        function [obj, dropped] = dropExpired(obj)
            dropped = [];
            for u = 1:obj.numUE
                q = obj.queues{u};
                if isempty(q), continue; end

                expired = arrayfun(@(p) isfinite(p.deadline) && p.deadline <= 0, q);
                if any(expired)
                    dropPkts = q(expired);
                    dropped = [dropped; dropPkts(:)]; %#ok<AGROW>
                    q = q(~expired);
                    obj.queues{u} = q;

                    if obj.enableStats
                        obj = obj.updateDropStats(dropPkts, "deadline");
                    end
                end
            end
        end

        function [obj, servedBits] = serve(obj, ueId, bits)
            servedBits = 0;
            q = obj.queues{ueId};

            while bits > 0 && ~isempty(q)

                take = min(bits, q(1).size);
                q(1).size = q(1).size - take;

                servedBits = servedBits + take;
                bits = bits - take;

                if q(1).size <= 0
                    if obj.enableStats
                        obj = obj.updateServeStats(q(1));
                    end
                    q(1) = [];
                end
            end

            obj.queues{ueId} = q;
        end

        function q = getQueue(obj, ueId)
            q = obj.queues{ueId};
        end
    end

    methods (Access = private)

        function obj = refreshMixWeightFromProfile(obj)
            for u = 1:obj.numUE
                t = obj.profileType(u);
                if t == "eMBB"
                    obj.mixWeight(u,:) = [0.92 0.06 0.02];
                elseif t == "URLLC"
                    obj.mixWeight(u,:) = [0.15 0.80 0.05];
                elseif t == "mMTC"
                    obj.mixWeight(u,:) = [0.08 0.04 0.88];
                else
                    obj.mixWeight(u,:) = [0.65 0.25 0.10];
                end
            end
            s = sum(obj.mixWeight, 2);
            obj.mixWeight = obj.mixWeight ./ max(s, 1e-12);
        end

        function dl = makeDeadlinePerUE(obj)
            % URLLC deadline per UE: URLLC-heavy gets tighter deadlines
            dl = obj.urllcDeadlineBase * ones(obj.numUE,1);
            for u = 1:obj.numUE
                if obj.profileType(u) == "URLLC"
                    dl(u) = max(3, round(obj.urllcDeadlineBase * 0.6));
                elseif obj.profileType(u) == "eMBB"
                    dl(u) = max(4, round(obj.urllcDeadlineBase * 1.1));
                else
                    dl(u) = obj.urllcDeadlineBase;
                end
            end
            % small randomness
            dl = max(2, dl + randi([-1 1], obj.numUE, 1));
        end

        function obj = advanceBurst(obj, u)
            for k = 1:3
                obj.remainCounter(u,k) = obj.remainCounter(u,k) - 1;
                if obj.remainCounter(u,k) <= 0
                    % toggle state
                    obj.onState(u,k) = ~obj.onState(u,k);
                    if obj.onState(u,k)
                        obj.remainCounter(u,k) = obj.sampleGeomSlots(obj.meanOnSlot(k));
                    else
                        obj.remainCounter(u,k) = obj.sampleGeomSlots(obj.meanOffSlot(k));
                    end
                end
            end
        end

        function n = sampleGeomSlots(~, meanSlots)
            % Geometric duration with given mean (>=1)
            meanSlots = max(1, meanSlots);
            p = 1 / meanSlots;
            n = 1;
            while rand > p
                n = n + 1;
                if n > 1e6
                    break;
                end
            end
        end

        function s = logNormalScale(~, n, mu, sigma)
            % lognormal with median exp(mu), moderate spread
            s = exp(mu + sigma*randn(n,1));
        end

        function n = poissonCount(~, lambda)
            if lambda <= 0
                n = 0;
                return;
            end
            L = exp(-lambda);
            k = 0;
            p = 1;
            while p > L
                k = k + 1;
                p = p * rand;
                if k > 10000
                    break;
                end
            end
            n = k - 1;
        end

        function pkt = createPacket(obj, ueId, sizeBits, deadlineSlots, typeStr)
            pkt.size     = sizeBits;
            pkt.deadline = deadlineSlots;
            pkt.type     = typeStr;
            pkt.age      = 0;
            pkt.ueId     = ueId;
            pkt.t0_slot  = obj.slotNow;
        end

        function obj = enqueueQoS(obj, ueId, pkt)
            % QoS-aware enqueue with buffer limit:
            % If buffer/qlen full, drop lower priority first.
            % Priority: URLLC > eMBB > mMTC

            q = obj.queues{ueId};

            % qlen limit
            if numel(q) >= obj.maxPacketsPerUE
                [q, droppedPkt] = obj.evictOneForQoS(q, pkt);
                if isempty(droppedPkt)
                    % accept by evicting someone
                    q = [q; pkt]; %#ok<AGROW>
                    obj.queues{ueId} = q;
                    if obj.enableStats, obj = obj.updateArrivalStats(pkt); end
                else
                    % cannot evict -> drop incoming
                    if obj.enableStats, obj = obj.updateDropStats(pkt, "qlen"); end
                end
                return;
            end

            % buffer bits limit
            buf = 0;
            if ~isempty(q), buf = sum([q.size]); end

            if buf + pkt.size > obj.maxBufferBitsPerUE
                [q, droppedPkt] = obj.evictOneForQoS(q, pkt);
                if isempty(droppedPkt)
                    q = [q; pkt]; %#ok<AGROW>
                    obj.queues{ueId} = q;
                    if obj.enableStats, obj = obj.updateArrivalStats(pkt); end
                else
                    if obj.enableStats, obj = obj.updateDropStats(pkt, "buffer"); end
                end
                return;
            end

            % normal enqueue
            q = [q; pkt]; %#ok<AGROW>
            obj.queues{ueId} = q;
            if obj.enableStats, obj = obj.updateArrivalStats(pkt); end
        end

        function [q, droppedPkt] = evictOneForQoS(~, q, incomingPkt)
            % Try to evict a lower-priority packet to make room.
            % Return droppedPkt if incoming is dropped. Return [] if eviction succeeded.

            droppedPkt = incomingPkt;

            if isempty(q)
                return;
            end

            pri = @(t) localPri(t); %#ok<NASGU>

            inP = localPri(incomingPkt.type);

            % find a packet with lower priority (larger number means lower priority)
            cand = [];
            candP = [];

            for i = 1:numel(q)
                p = localPri(q(i).type);
                if p > inP
                    cand(end+1,1) = i; %#ok<AGROW>
                    candP(end+1,1) = p; %#ok<AGROW>
                end
            end

            if isempty(cand)
                % no lower-priority packet to evict -> drop incoming
                return;
            end

            % evict the lowest priority among candidates, if tie evict the largest packet
            bestIdx = cand(1);
            for k = 2:numel(cand)
                i = cand(k);
                if candP(k) > localPri(q(bestIdx).type)
                    bestIdx = i;
                elseif candP(k) == localPri(q(bestIdx).type)
                    if q(i).size > q(bestIdx).size
                        bestIdx = i;
                    end
                end
            end

            % evict q(bestIdx)
            q(bestIdx) = [];
            droppedPkt = []; % eviction succeeded
        end

        function s = initStats(~)
            s = struct();
            s.arrival = struct('eMBB',0,'URLLC',0,'mMTC',0);
            s.drop = struct();
            s.drop.total = 0;
            s.drop.byType = struct('eMBB',0,'URLLC',0,'mMTC',0);
            s.drop.byCause = struct('deadline',0,'buffer',0,'qlen',0);
            s.serve = struct();
            s.serve.completedPkts = struct('eMBB',0,'URLLC',0,'mMTC',0);
            s.serve.delaySlotSum  = struct('eMBB',0,'URLLC',0,'mMTC',0);
        end

        function obj = updateArrivalStats(obj, pkt)
            if isfield(obj.stats.arrival, pkt.type)
                obj.stats.arrival.(pkt.type) = obj.stats.arrival.(pkt.type) + 1;
            end
        end

        function obj = updateDropStats(obj, pkts, cause)
            if ~isstruct(pkts), return; end
            pkts = pkts(:);

            for i = 1:numel(pkts)
                t = pkts(i).type;
                obj.stats.drop.total = obj.stats.drop.total + 1;
                if isfield(obj.stats.drop.byType, t)
                    obj.stats.drop.byType.(t) = obj.stats.drop.byType.(t) + 1;
                end
                if isfield(obj.stats.drop.byCause, cause)
                    obj.stats.drop.byCause.(cause) = obj.stats.drop.byCause.(cause) + 1;
                end
            end
        end

        function obj = updateServeStats(obj, pkt)
            t = pkt.type;
            if isfield(obj.stats.serve.completedPkts, t)
                obj.stats.serve.completedPkts.(t) = obj.stats.serve.completedPkts.(t) + 1;
            end
            if isfield(obj.stats.serve.delaySlotSum, t)
                obj.stats.serve.delaySlotSum.(t) = obj.stats.serve.delaySlotSum.(t) + pkt.age;
            end
        end
    end
end

function p = localPri(typeStr)
% smaller is higher priority
if strcmp(typeStr,'URLLC')
    p = 1;
elseif strcmp(typeStr,'eMBB')
    p = 2;
else
    p = 3;
end
end
