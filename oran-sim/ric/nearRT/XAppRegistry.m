classdef XAppRegistry < handle
% XAPPREGISTRY v2 (Simplified registry format)
%
% Compatible with minimal registry.json:
% {
%   xapp_id,
%   name,
%   version,
%   description,
%   control_parameters,
%   kpi_objectives,
%   kpi_constraints,
%   expected_standalone_effect
% }
%
% Design:
% - entry_point defaults to xapp_id
% - execution_type defaults to "periodic"
%

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
                reg_file  = fullfile(xapp_path, "registry.json");

                if ~exist(reg_file, "file")
                    continue;
                end

                reg = readstruct(reg_file, "FileType", "json");

                %% -------------------------
                % Basic validation
                %% -------------------------
                if ~isfield(reg, "xapp_id")
                    error("XAppRegistry:MissingField", ...
                        "registry.json missing xapp_id in %s", xapp_path);
                end

                %% -------------------------
                % Build descriptor
                %% -------------------------
                desc = struct();

                desc.xapp_id   = string(reg.xapp_id);
                desc.name      = string(reg.name);
                desc.version   = string(reg.version);
                desc.description = string(reg.description);

                % Entry point default = xapp_id
                desc.entry_point = string(reg.xapp_id);

                % Default execution type
                desc.execution_type = "periodic";

                % Optional fields
                if isfield(reg, "control_parameters")
                    desc.control_parameters = reg.control_parameters;
                else
                    desc.control_parameters = {};
                end

                if isfield(reg, "kpi_objectives")
                    desc.kpi_objectives = reg.kpi_objectives;
                else
                    desc.kpi_objectives = struct();
                end

                if isfield(reg, "kpi_constraints")
                    desc.kpi_constraints = reg.kpi_constraints;
                else
                    desc.kpi_constraints = struct();
                end

                if isfield(reg, "expected_standalone_effect")
                    desc.expected_standalone_effect = reg.expected_standalone_effect;
                else
                    desc.expected_standalone_effect = struct();
                end

                desc.path   = xapp_path;
                desc.status = "off";

                obj.xapps = [obj.xapps; desc]; %#ok<AGROW>

            end

        end

        function xapps = getXApps(obj)
            xapps = obj.xapps;
        end

    end
end