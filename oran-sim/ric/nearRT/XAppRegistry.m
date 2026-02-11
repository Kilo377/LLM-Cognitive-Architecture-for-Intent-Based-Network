classdef XAppRegistry < handle

    properties
        xapp_root
        xapps   % struct array
    end

    methods

        function obj = XAppRegistry(xapp_root)
            obj.xapp_root = xapp_root;
            obj.xapps = [];
        end

        function load(obj)
            dirs = dir(obj.xapp_root);

            for i = 1:numel(dirs)

                d = dirs(i);
                if ~d.isdir
                    continue;
                end
                if startsWith(d.name, ".")
                    continue;
                end

                xapp_path = fullfile(obj.xapp_root, d.name);
                reg_file = fullfile(xapp_path, "registry.json");


                if ~exist(reg_file, "file")
                    continue;
                end

                % 读取 yaml
                reg = readstruct(reg_file, "FileType", "json");

                desc = struct();
                desc.xapp_id = string(reg.xapp_id);
                desc.entry_point = string(reg.entry_point);
                desc.execution_type = string(reg.execution_type);
                desc.control_parameters = reg.control_parameters;
                desc.affected_kpis = reg.affected_kpis;
                desc.path = xapp_path;
                desc.status = "off";

                obj.xapps = [obj.xapps; desc]; %
            end
        end

        function xapps = getXApps(obj)
            xapps = obj.xapps;
        end

    end
end
