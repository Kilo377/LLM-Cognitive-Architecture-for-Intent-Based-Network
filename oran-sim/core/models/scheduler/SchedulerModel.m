classdef SchedulerModel
    methods

        function ctx = step(~, ctx)

            numCell = ctx.cfg.scenario.numCell;

            % 初始化 scheduledUE
            ctx.tmp.scheduledUE = zeros(numCell,1);

            for c = 1:numCell

                ueSet = find(ctx.servingCell == c);

                ctx.accPRBTotalPerCell(c) = ...
                    ctx.accPRBTotalPerCell(c) + ctx.numPRB;

                if isempty(ueSet)
                    continue;
                end

                k = mod(ctx.rrPtr(c)-1, numel(ueSet)) + 1;
                u = ueSet(k);

                ctx.rrPtr(c) = ctx.rrPtr(c) + 1;

                % 只记录，不执行
                ctx.tmp.scheduledUE(c) = u;

            end

        end
    end
end
