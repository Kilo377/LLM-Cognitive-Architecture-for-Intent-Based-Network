function [useSmall, reward, info] = nearRT_policy_all_macro(state)
% nearRT_policy_all_macro
% -------------------------------------------------------------------------
% 近实时策略：所有 UE 都走宏小区（不 offload 到小小区）

numUEs = state.numUEs;
useSmall = false(1, numUEs);  % 全部走宏
reward = 0;
info = struct("name", "nearrt_macro_only", ...
              "desc", "所有 UE 只连接宏小区。");
end
