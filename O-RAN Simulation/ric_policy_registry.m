function reg = ric_policy_registry()
% ric_policy_registry
% -------------------------------------------------------------------------
% 策略库注册表：
%   reg.nonRT(id)  -> 非实时策略 function handle
%   reg.nearRT(id) -> 近实时策略 function handle
%   reg.beam(id)   -> beam 策略元信息（算法在 nearRT_beam_ric.m 中按 ID 选）

    reg.nonRT  = containers.Map();
    reg.nearRT = containers.Map();
    reg.beam   = containers.Map();

    %% ===== Non-RT 策略 =====
    reg.nonRT("nonrt_baseline")       = @nonRT_policy_baseline_all_on;
    reg.nonRT("nonrt_energy_simple")  = @nonRT_policy_energy_simple;

    %% ===== near-RT 策略 =====
    reg.nearRT("nearrt_macro_only")      = @nearRT_policy_all_macro;
    reg.nearRT("nearrt_smallcell_bias")  = @nearRT_policy_smallcell_bias;

    %% ===== beam 策略（元信息） =====
    reg.beam("beam_default") = struct( ...
        "id",   "beam_default", ...
        "desc", "兼容旧逻辑，等价于 beam_random。");

    reg.beam("beam_random") = struct( ...
        "id",   "beam_random", ...
        "desc", "每个 UE 独立随机选择 beam。");

    reg.beam("beam_round_robin") = struct( ...
        "id",   "beam_round_robin", ...
        "desc", "按 RNTI 做 round-robin 映射，减少随机波动。");

    reg.beam("beam_fixed_center") = struct( ...
        "id",   "beam_fixed_center", ...
        "desc", "所有 UE 使用同一个中心 beam，用于对比。");
end
