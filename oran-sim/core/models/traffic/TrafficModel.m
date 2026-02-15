classdef TrafficModel
%TRAFFICMODEL Simple multi-service traffic model for NR simulation

    properties
        numUE
        slotDuration

        % Traffic configuration
        embbRate
        urllcRate
        mmtcRate

        embbPktSize
        urllcPktSize
        mmtcPktSize

        urllcDeadline
        mmtcDeadline

        % Packet queues
        queues   % cell array {numUE}
    end

    methods
        function obj = TrafficModel(varargin)
            p = inputParser;
            addParameter(p, 'numUE', 10);
            addParameter(p, 'slotDuration', 1e-3);
            parse(p, varargin{:});

            obj.numUE        = p.Results.numUE;
            obj.slotDuration = p.Results.slotDuration;

            % Arrival rates (packet / second)
            obj.embbRate  = 50;
            obj.urllcRate = 10;
            obj.mmtcRate  = 5;

            % Packet sizes (bit)
            obj.embbPktSize  = 1e6;
            obj.urllcPktSize = 3e4;
            obj.mmtcPktSize  = 1e3;

            % Deadlines (slot)
            obj.urllcDeadline = 10;
            obj.mmtcDeadline  = 100;

            % Init queues
            obj.queues = cell(obj.numUE,1);
            for u = 1:obj.numUE
                obj.queues{u} = [];
            end
        end

        function obj = step(obj)
            %STEP Generate new packets

            for u = 1:obj.numUE
                % eMBB
                if rand < obj.embbRate * obj.slotDuration
                    pkt = obj.createPacket( ...
                        obj.embbPktSize, inf, 'eMBB');
                    obj.queues{u} = [obj.queues{u}; pkt];
                end

                % URLLC
                if rand < obj.urllcRate * obj.slotDuration
                    pkt = obj.createPacket( ...
                        obj.urllcPktSize, obj.urllcDeadline, 'URLLC');
                    obj.queues{u} = [obj.queues{u}; pkt];
                end

                % mMTC
                if rand < obj.mmtcRate * obj.slotDuration
                    pkt = obj.createPacket( ...
                        obj.mmtcPktSize, obj.mmtcDeadline, 'mMTC');
                    obj.queues{u} = [obj.queues{u}; pkt];
                end
            end
        end

        function obj = decreaseDeadline(obj)
            % Decrease deadline of all packets
            for u = 1:obj.numUE
                if isempty(obj.queues{u})
                    continue;
                end
                for k = 1:length(obj.queues{u})
                    if isfinite(obj.queues{u}(k).deadline)
                        obj.queues{u}(k).deadline = ...
                            obj.queues{u}(k).deadline - 1;
                    end
                end
            end
        end

        function [obj, dropped] = dropExpired(obj)
            % Drop expired packets
            dropped = [];
            for u = 1:obj.numUE
                q = obj.queues{u};
                if isempty(q)
                    continue;
                end
                expired = arrayfun(@(p) p.deadline <= 0, q);
                dropped = [dropped; q(expired)]; %#ok<AGROW>
                obj.queues{u} = q(~expired);
            end
        end

        function [obj, servedBits] = serve(obj, ueId, bits)
            %SERVE Serve bits for UE ueId
            servedBits = 0;
            q = obj.queues{ueId};

            while bits > 0 && ~isempty(q)
                if q(1).size <= bits
                    bits = bits - q(1).size;
                    servedBits = servedBits + q(1).size;
                    q(1) = [];
                else
                    q(1).size = q(1).size - bits;
                    servedBits = servedBits + bits;
                    bits = 0;
                end
            end

            obj.queues{ueId} = q;
        end

        function q = getQueue(obj, ueId)
            q = obj.queues{ueId};
        end
    end

    methods (Access = private)
        function pkt = createPacket(~, size, deadline, type)
            pkt.size     = size;
            pkt.deadline = deadline;
            pkt.type     = type;
        end
    end
end
