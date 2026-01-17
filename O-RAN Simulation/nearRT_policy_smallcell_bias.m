function [useSmall, reward, info] = nearRT_policy_smallcell_bias(state)
% nearRT_policy_smallcell_bias
% -------------------------------------------------------------------------
% 近实时策略：简单负载感知 small cell offload
%   - 若 UE 对应的小小区 active 且 LR(sc) < 0.7，则 offload 到小小区
%   - 否则留在宏小区

numUEs   = state.numUEs;
numCells = state.numCells;

useSmall    = false(1, numUEs);
cellActive  = state.cellActive;
ueSmallCell = state.ueSmallCell;
LR          = state.LR;

for u = 1:numUEs
    sc = ueSmallCell(u);
    if sc >= 2 && sc <= numCells
        if cellActive(sc) && (LR(sc) < 0.7)
            useSmall(u) = true;
        else
            useSmall(u) = false;
        end
    else
        useSmall(u) = false;
    end
end

reward = 0;
info = struct("name", "nearrt_smallcell_bias", ...
              "desc", "在 active 且负载不高的小小区上优先 offload UE。");
end
