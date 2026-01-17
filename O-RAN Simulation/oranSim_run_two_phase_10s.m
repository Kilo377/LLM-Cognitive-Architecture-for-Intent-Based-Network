function resPath = oranSim_run_two_phase_10s(roundIdx, prevPolicy, currPolicy, intentDesc, resultDir)
% oranSim_run_two_phase_10s
% 封装一次 two-phase 仿真，并把 KPI 写成 res_round_<roundIdx>.json
%
% 输入：
%   roundIdx   : 本轮编号（0,1,2,...）
%   prevPolicy : struct('nonRT',..,'nearRT',..,'beam',..)，上一轮策略
%   currPolicy : struct('nonRT',..,'nearRT',..,'beam',..)，当前轮要用的策略
%   intentDesc : 自然语言意图（给 summary agent 看）
%   resultDir  : 结果目录，例如 "D:/oran_logs/sim_results"
%
% 输出：
%   resPath    : 写出的 JSON 路径（给 Python 那边用）

    if nargin < 1 || isempty(roundIdx)
        roundIdx = 0;
    end
    if nargin < 2 || isempty(prevPolicy)
        prevPolicy = struct( ...
            "nonRT",  "nonrt_baseline", ...
            "nearRT", "nearrt_macro_only", ...
            "beam",   "beam_default");
    end
    if nargin < 3 || isempty(currPolicy)
        currPolicy = prevPolicy;
    end
    if nargin < 4 || isempty(intentDesc)
        intentDesc = "";
    end
    if nargin < 5 || isempty(resultDir)
        resultDir = "D:/oran_logs/sim_results";
    end

    if ~exist(resultDir, "dir")
        mkdir(resultDir);
    end

    % ===== 1) 调用核心仿真函数（2s，后1s算KPI） =====
    % 要求 oranSim_RL_step_light(prevPolicy, currPolicy) 返回：
    %   simKPI   : struct，含 totalTputMbps / ueTput5 / ueTput50 / ueTput95 / estimatedEnergyW / sleepRatioSmall
    %   cellEntry: struct，含 cell_id / throughput_Mbps / delay_ms / load_ratio / power_norm / energyEff_MbpsPerPower
    %   ueEntry  : struct，含 ue_id / throughput_Mbps / delay_ms / serving_cell / energyEff_MbpsPerPower (/ traffic_type 可选)
    [simKPI, cellEntry, ueEntry] = oranSim_RL_step_light(prevPolicy, currPolicy);

    % ===== 2) 组装 sim_result 结构体（给 summary agent 用） =====
    simResult = struct();

    % 实验 ID
    simResult.exp_id = sprintf("exp_round_%d", roundIdx);

    % 意图自然语言
    simResult.intent_desc = char(intentDesc);

    % 策略 ID（用"当前轮生效"的 currPolicy）
    pol = struct();
    if isfield(currPolicy, "nonRT"),  pol.nonRT  = char(currPolicy.nonRT);  else, pol.nonRT  = ""; end
    if isfield(currPolicy, "nearRT"), pol.nearRT = char(currPolicy.nearRT); else, pol.nearRT = ""; end
    if isfield(currPolicy, "beam"),   pol.beam   = char(currPolicy.beam);   else, pol.beam   = ""; end
    simResult.policy_ids = pol;

    % === KPI 总表（基于 second-phase [1,2] s） ===
    kpi = struct();
    if isfield(simKPI,"totalTputMbps"),        kpi.sum_tput_Mbps = simKPI.totalTputMbps;      else, kpi.sum_tput_Mbps = NaN; end
    if isfield(simKPI,"ueTput5"),              kpi.ue_tput_5p    = simKPI.ueTput5;            else, kpi.ue_tput_5p    = NaN; end
    if isfield(simKPI,"ueTput50"),             kpi.ue_tput_50p   = simKPI.ueTput50;           else, kpi.ue_tput_50p   = NaN; end
    if isfield(simKPI,"ueTput95"),             kpi.ue_tput_95p   = simKPI.ueTput95;           else, kpi.ue_tput_95p   = NaN; end
    if isfield(simKPI,"estimatedEnergyW"),     kpi.estimated_energy_W = simKPI.estimatedEnergyW; else, kpi.estimated_energy_W = NaN; end
    if isfield(simKPI,"sleepRatioSmall"),      kpi.sleep_ratio_small_cells = simKPI.sleepRatioSmall; else, kpi.sleep_ratio_small_cells = NaN; end

    kpi.time_window_s = [1.0, 2.0];   % 明确写出我们只看后 1s
    simResult.kpi = kpi;

    % === 小区级 KPI（来自 cellEntry） ===
    numCells = numel(cellEntry.cell_id);

    % 用"模板 struct"预分配，避免"不同结构体之间下标赋值"错误
    templateCell = struct( ...
        "cell_id", 0, ...
        "role", '', ...
        "tput_Mbps", 0.0, ...
        "delay_ms", 0.0, ...
        "power_W", 0.0, ...
        "load_ratio", 0.0, ...
        "energyEff_MbpsPerPower", 0.0);

    cells = repmat(templateCell, numCells, 1);

    for c = 1:numCells
        cells(c).cell_id  = cellEntry.cell_id(c);

        if c == 1
            cells(c).role = 'macro';
        else
            cells(c).role = 'small';
        end

        cells(c).tput_Mbps   = cellEntry.throughput_Mbps(c);
        cells(c).delay_ms    = cellEntry.delay_ms(c);
        cells(c).power_W     = cellEntry.power_norm(c);            % 抽象功耗（相对值）
        cells(c).load_ratio  = cellEntry.load_ratio(c);
        cells(c).energyEff_MbpsPerPower = cellEntry.energyEff_MbpsPerPower(c);
    end
    simResult.cells = cells;

    % === UE 级 KPI（物理 UE） ===
    numUEs = numel(ueEntry.ue_id);

    templateUE = struct( ...
        "ue_id", 0, ...
        "tput_Mbps", 0.0, ...
        "delay_ms", 0.0, ...
        "serving_cell", 0, ...
        "energyEff_MbpsPerPower", 0.0, ...
        "service", '');

    ues = repmat(templateUE, numUEs, 1);

    % traffic_type 字段是可选的：如果存在，就用它映射成业务名；否则统一 Unknown
    hasTrafficType = isfield(ueEntry, "traffic_type");
    if hasTrafficType
        trafficVec = ueEntry.traffic_type;
    else
        trafficVec = [];
    end

    for p = 1:numUEs
        ues(p).ue_id        = ueEntry.ue_id(p);
        ues(p).tput_Mbps    = ueEntry.throughput_Mbps(p);
        ues(p).delay_ms     = ueEntry.delay_ms(p);
        ues(p).serving_cell = ueEntry.serving_cell(p);
        ues(p).energyEff_MbpsPerPower = ueEntry.energyEff_MbpsPerPower(p);

        svc = 'Unknown';
        if hasTrafficType && p <= numel(trafficVec)
            tt = trafficVec(p);
            % 按照 appType: 1=Video, 2=Gaming, 3=Voice, 4=URLLC
            switch tt
                case 1
                    svc = 'Video';
                case 2
                    svc = 'Gaming';
                case 3
                    svc = 'Voice';
                case 4
                    svc = 'URLLC';
                otherwise
                    svc = 'Unknown';
            end
        end
        ues(p).service = svc;
    end
    simResult.ues = ues;

    % 暂时不做"bad_ues"检测，先给一个空数组，后面可以在 Matlab 或 Python 里筛选
    simResult.bad_ues = [];

    % ===== 3) 写 JSON 文件 =====
    resName = sprintf("res_round_%d.json", roundIdx);
    resPath = fullfile(resultDir, resName);

    try
        % PrettyPrint 旧版 Matlab 可能没有，所以加一个 try/catch
        try
            txt = jsonencode(simResult, "PrettyPrint", true);
        catch
            txt = jsonencode(simResult);
        end

        fid = fopen(resPath, "w");
        if fid == -1
            error("无法打开结果文件: %s", resPath);
        end
        fwrite(fid, txt, "char");
        fclose(fid);

        fprintf("结果已写入: %s\n", resPath);
    catch ME
        warning("写 JSON 结果文件失败：%s", ME.message);
        resPath = "";
    end
end
