classdef XAppManager < handle

    properties
        xapps   % struct array of xApp descriptors
    end

    methods

        function obj = XAppManager(xapp_list)
            obj.xapps = xapp_list;
        end

        function setXAppStatus(obj, xapp_id, status)
            for i = 1:numel(obj.xapps)
                if strcmp(obj.xapps(i).xapp_id, xapp_id)
                    obj.xapps(i).status = status;
                    return;
                end
            end
        end

        function actions = run(obj, input, ~)
            % 所有 status="on" 的 xApp 都运行
            % trigger_type 参数保留但不使用

            actions = {};

            for i = 1:numel(obj.xapps)

                xapp = obj.xapps(i);

                if ~strcmp(xapp.status, "on")
                    continue;
                end

                % 加载路径
                addpath(xapp.path);

                % 调用 xApp
                action = feval(xapp.entry_point, input);

                if ~isfield(action,"metadata") || ~isstruct(action.metadata)
                    action.metadata = struct();
                end
                if ~isfield(action.metadata,"source")
                    action.metadata.source = string(xapp.xapp_id);
                end

                % ===== Debug dump =====
                if isfield(input,"context") && isfield(input.context,"time")
                    slot = input.context.time.slot;
                else
                    slot = -1;
                end
                
                if slot <= 3
                    fprintf("\n=== xApp return dump (slot=%d) id=%s ===\n", ...
                        slot, xapp.xapp_id);

                    disp(fieldnames(action));

                    if isfield(action,"radio")
                        fprintf("radio fields:\n");
                        disp(fieldnames(action.radio));
                        if isfield(action.radio,"bandwidthScale")
                            fprintf("  bwMean=%.2f\n", ...
                                mean(action.radio.bandwidthScale));
                        end
                        if isfield(action.radio,"txPowerOffset_dB")
                            fprintf("  txOffMean=%.2f\n", ...
                                mean(action.radio.txPowerOffset_dB));
                        end
                    end

                    if isfield(action,"energy")
                        fprintf("energy fields:\n");
                        disp(fieldnames(action.energy));
                        if isfield(action.energy,"basePowerScale")
                            fprintf("  basePwrMean=%.2f\n", ...
                                mean(action.energy.basePowerScale));
                        end
                    end
                end
                if slot > 0
                    doPrint = false;
                    every = 200;
                    if isfield(input,"config") && isfield(input.config,"debug")
                        if isfield(input.config.debug,"enableNearRT") && input.config.debug.enableNearRT
                            doPrint = true;
                        end
                        if isfield(input.config.debug,"nearRTEvery") && isnumeric(input.config.debug.nearRTEvery)
                            every = max(1, round(input.config.debug.nearRTEvery));
                        end
                    end
                    if doPrint && mod(slot, every) == 0
                        fprintf('[near-RT RIC][xAppManager] slot=%d ran=%s\n', slot, xapp.xapp_id);
                    end
                end
                % ======================

                actions{end+1} = action; %#ok<AGROW>
            end
        end

    end
end
