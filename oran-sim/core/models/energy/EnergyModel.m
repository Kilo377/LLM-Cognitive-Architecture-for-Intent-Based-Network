classdef (Abstract) EnergyModel
    methods (Abstract)
        ctx = step(obj, ctx);
    end
end
