function [cellActiveAction, reward, info] = nonRT_policy_baseline_all_on(state)
% nonRT_policy_baseline_all_on
% -------------------------------------------------------------------------
% 非实时策略：所有小区（宏+小小区）都保持开启

numCells = state.numCells;
cellActiveAction = true(1, numCells);
reward = 0;
info = struct("name", "nonrt_baseline_all_on", ...
              "desc", "所有小区常开，不做节能。");
end
