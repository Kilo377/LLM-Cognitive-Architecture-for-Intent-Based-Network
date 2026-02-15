classdef (Abstract) KPIModel
    methods (Abstract)
        ctx = step(obj, ctx);
    end
end
