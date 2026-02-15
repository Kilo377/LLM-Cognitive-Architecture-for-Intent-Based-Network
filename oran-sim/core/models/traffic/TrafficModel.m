classdef TrafficModel
%TRAFFICMODEL v2: Multi-service traffic with UE profiles and burstiness
%
% API compatible with existing kernel/models:
%   obj = obj.step()
%   obj = obj.decreaseDeadline()
%   [obj, dropped] = obj.dropExpired()
%   [obj, servedBits] = obj.serve(ueId, bits)
%   q = obj.getQueue(ueId)
%
% Packet struct fields:
%   .size      (bits)
%   .deadline  (slots) (inf for eMBB)
%   .type      ('eMBB'/'URLLC'/'mMTC')
%   .age       (slots)
%   .ueId
%   .t0_slot   (arrival slot index)

    properties
        numUE
        slotDuration

        % UE profile: weights for traffic mix
        profileType          % string array [numUEx1]: "eMBB"/"Mixed"/"URLLC"/"mMTC"
        mixWeight            % [numUE x 3] weights [eMBB URLLC mMTC] normalized

        % Base arrival rates (packets/sec) per service for a "typical" UE
        baseRate_embb
        baseRate_urllc
        baseRate_mmtc

        % Packet sizes (bits)
        embbPktSizeMean
        embbPktSizeStd
        urllcPktSize
        mmtcPktSize

        % Deadlines (slots)
        urllcDeadline
        mmtcDeadline

        % Burstiness (ON/OFF) per UE per service
        enableBurst
        onProb             % probability to remain ON
        offProb            % probability to remain OFF
        onState            % [numUE x 3] logical

        % Queue constraints
        maxBufferBitsPerUE
        maxPacketsPerUE

        % Runtime
        slotNow
        queues             % cell {numUE} of packet arrays

        % Stats (optional)
        stats
        enableStats
    end

    methods
        function obj = TrafficModel(varargin)

            p = inputParser;
            addParameter(p, 'numUE', 10);
            addParameter(p, 'slotDuration', 1e-3);
            addParameter(p, 'enableBurst', true);
            addParameter(p, 'enableStats', true);
            parse(p, varargin{:});

            obj.numUE        = p.Results.numUE;
            obj.slotDuration = p.Results.slotDuration;

            obj.enableBurst  = p.Results.enableBurst;
            obj.enableStats  = p.Results.enableStats;

            obj.slotNow = 0;

            % Base rates (pkts/sec)
            obj.baseRate_embb  = 30;
            obj.baseRate_urllc = 10;
            obj.baseRate_mmtc  = 3;

            % Sizes
            obj.embbPktSizeMean = 5e5;   % 0.5 Mbit mean (more reasonable than 1e6 baseline)
            obj.embbPktSizeStd  = 2e5;   % variability
            obj.urllcPktSize    = 3e4;   % 30 kbit
            obj.mmtcPktSize     = 2e3;   % 2 kbit

            % Deadlines
            obj.urllcDeadline = 8;      % 8 ms if slot=1ms
            obj.mmtcDeadline  = 200;    % relaxed

            % Burst parameters (sticky ON/OFF)
            obj.onProb  = 0.95;
            obj.offProb = 0.90;

            obj.onState = true(obj.numUE,3);

            % Buffer limits
            obj.maxBufferBitsPerUE = 20e6;   % 20 Mbits
            obj.maxPacketsPerUE    = 2000;

            % UE profiles: default mixed
            obj.profileType = repmat("Mixed", obj.numUE, 1);
            obj.mixWeight   = repmat([0.7 0.2 0.1], obj.numUE, 1);

            % Example: make a few UEs special (can be configured later)
            if obj.numUE >= 10
                obj.profileType(1:4) = "eMBB";
                obj.profileType(5:7) = "Mixed";
                obj.profileType(8:9) = "URLLC";
                obj.profileType(10)  = "mMTC";
            end
            obj = obj.refreshMixWeightFromProfile();

            % Init queues
            obj.queues = cell(obj.numUE,1);
            for u = 1:obj.numUE
                obj.queues{u} = [];
            end

            % Stats
            obj.stats = obj.initStats();
        end

        function obj = step(obj)
            %STEP Generate arrivals for all UEs

            obj.slotNow = obj.slotNow + 1;

            for u = 1:obj.numUE

                % Update ON/OFF state if enabled
                if obj.enableBurst
                    obj.onState(u,:) = obj.updateOnOff(obj.onState(u,:));
                end

                % Effective rates per UE (apply mix weights)
                w = obj.mixWeight(u,:);
                rate_embb  = obj.baseRate_embb  * w(1);
                rate_urllc = obj.baseRate_urllc * w(2);
                rate_mmtc  = obj.baseRate_mmtc  * w(3);

                % Apply ON/OFF gating
                if obj.enableBurst
                    if ~obj.onState(u,1), rate_embb = rate_embb * 0.1; end
                    if ~obj.onState(u,2), rate_urllc = rate_urllc * 0.2; end
                    if ~obj.onState(u,3), rate_mmtc = rate_mmtc * 0.1; end
                end

                % Poisson arrivals: number of packets in this slot
                nE = obj.poissonCount(rate_embb  * obj.slotDuration);
                nU = obj.poissonCount(rate_urllc * obj.slotDuration);
                nM = obj.poissonCount(rate_mmtc  * obj.slotDuration);

                % Create packets
                for k = 1:nE
                    sz = max(1e4, obj.embbPktSizeMean + obj.embbPktSizeStd*randn());
                    pkt = obj.createPacket(u, sz, inf, 'eMBB');
                    obj = obj.enqueue(u, pkt);
                end
                for k = 1:nU
                    pkt = obj.createPacket(u, obj.urllcPktSize, obj.urllcDeadline, 'URLLC');
                    obj = obj.enqueue(u, pkt);
                end
                for k = 1:nM
                    pkt = obj.createPacket(u, obj.mmtcPktSize, obj.mmtcDeadline, 'mMTC');
                    obj = obj.enqueue(u, pkt);
                end
            end
        end

        function obj = decreaseDeadline(obj)
            % Decrease deadline and increase age
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
            % Drop packets whose deadline <= 0
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
            %SERVE Serve bits for UE ueId, FIFO within UE.
            servedBits = 0;

            q = obj.queues{ueId};

            while bits > 0 && ~isempty(q)

                take = min(bits, q(1).size);
                q(1).size = q(1).size - take;

                servedBits = servedBits + take;
                bits = bits - take;

                if q(1).size <= 0
                    % packet complete -> stats
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
                    obj.mixWeight(u,:) = [0.9 0.08 0.02];
                elseif t == "URLLC"
                    obj.mixWeight(u,:) = [0.2 0.75 0.05];
                elseif t == "mMTC"
                    obj.mixWeight(u,:) = [0.1 0.05 0.85];
                else
                    obj.mixWeight(u,:) = [0.7 0.2 0.1];
                end
            end
            % normalize
            s = sum(obj.mixWeight,2);
            obj.mixWeight = obj.mixWeight ./ s;
        end

        function on = updateOnOff(obj, on)
            % Sticky Markov ON/OFF per service
            for k = 1:3
                if on(k)
                    % stay ON with onProb
                    on(k) = (rand < obj.onProb);
                else
                    % stay OFF with offProb
                    on(k) = ~(rand < obj.offProb);
                end
            end
        end

        function n = poissonCount(~, lambda)
            % Poisson random count, lambda can be < 1
            if lambda <= 0
                n = 0;
                return;
            end
            % Knuth algorithm for small lambda
            L = exp(-lambda);
            k = 0;
            p = 1;
            while p > L
                k = k + 1;
                p = p * rand;
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

        function obj = enqueue(obj, ueId, pkt)

            q = obj.queues{ueId};

            % queue length limit
            if numel(q) >= obj.maxPacketsPerUE
                if obj.enableStats
                    obj = obj.updateDropStats(pkt, "qlen");
                end
                return;
            end

            % buffer bits limit
            buf = 0;
            if ~isempty(q)
                buf = sum([q.size]);
            end
            if buf + pkt.size > obj.maxBufferBitsPerUE
                if obj.enableStats
                    obj = obj.updateDropStats(pkt, "buffer");
                end
                return;
            end

            q = [q; pkt]; %#ok<AGROW>
            obj.queues{ueId} = q;

            if obj.enableStats
                obj = obj.updateArrivalStats(pkt);
            end
        end

        function s = initStats(obj) %#ok<MANU>
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
            obj.stats.arrival.(pkt.type) = obj.stats.arrival.(pkt.type) + 1;
        end

        function obj = updateDropStats(obj, pkts, cause)
            if ~isstruct(pkts)
                return;
            end
            if numel(pkts) == 1
                pkts = pkts(:);
            end
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
            obj.stats.serve.completedPkts.(t) = obj.stats.serve.completedPkts.(t) + 1;
            delay = pkt.age;
            obj.stats.serve.delaySlotSum.(t) = obj.stats.serve.delaySlotSum.(t) + delay;
        end
    end
end
