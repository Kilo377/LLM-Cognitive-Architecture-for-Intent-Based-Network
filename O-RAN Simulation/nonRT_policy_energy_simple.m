function [cellActiveAction, reward, info] = nonRT_policy_energy_simple(state)
% nonRT_policy_energy_simple
% -------------------------------------------------------------------------
% 简单节能策略：
%   - 宏小区永远开启
%   - 对于小小区，如果负载比例 LR(c) < 0.1，则关闭

numCells = state.numCells;
LR       = state.LR;

cellActiveAction = true(1, numCells);
for c = 2:numCells
    if LR(c) < 0.1
        cellActiveAction(c) = false;
    else
        cellActiveAction(c) = true;
    end
end

reward = 0;  % 如需 RL 可在此定义 reward
info = struct("name", "nonrt_energy_simple", ...
              "desc", "关闭低负载小小区以节能。");
end
