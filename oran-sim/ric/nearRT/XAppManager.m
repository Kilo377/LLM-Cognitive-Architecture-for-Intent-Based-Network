classdef XAppManager < handle

    properties
        xapps   % struct array of xApp descriptors
    end

    methods

        function obj = XAppManager(xapp_list)
            % xapp_list: struct array
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

        function actions = run(obj, input, trigger_type)
            % trigger_type: 'periodic' | 'event'

            actions = {};

            for i = 1:numel(obj.xapps)

                xapp = obj.xapps(i);

                if ~strcmp(xapp.status, "on")
                    continue;
                end

                if ~strcmp(xapp.execution_type, trigger_type)
                    continue;
                end

                % 加载路径
                addpath(xapp.path);

                % 调用 xApp
                action = feval(xapp.entry_point, input);

                actions{end+1} = action; %#ok<AGROW>
            end
        end

    end
end
