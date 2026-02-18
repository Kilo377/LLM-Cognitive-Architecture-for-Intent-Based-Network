function result = run_control_sensitivity()
%RUN_CONTROL_SENSITIVITY_V5
% Sweep all controllable knobs in RanActionBus.
% It reports KPI impact vs baseline.
%
% Output:
%   result.table  : MATLAB table
%   result.matrix : numeric matrix (same order as table columns)
%
% Notes:
% - It reads runtime metrics from ran.ctx to avoid tmp-state mismatch.
% - Some knobs may have no effect yet. The table will show it.

    rootDir = setup_path();
    cfgBase = default_config();

    if ~isfield(cfgBase,'nearRT')
        cfgBase.nearRT = struct();
    end
    cfgBase.nearRT.periodSlot = 10;
    cfgBase.nearRT.xappRoot   = fullfile(rootDir,"xapps");

    totalSlot = round(0.2 * 10000);
    cfgBase.sim.slotPerEpisode = totalSlot;

    % -------------------------------
    % Build experiment list
    % -------------------------------
    expList = build_experiments(cfgBase);

    fprintf('\n========== Sensitivity v5 ==========\n');
    fprintf('SlotPerEpisode = %d\n', totalSlot);
    fprintf('%-18s %-8s %-8s %-10s %-8s %-8s %-8s %-6s %-6s %-8s %-8s %-8s\n', ...
        'Exp','Thr(M)','Energy','Eff(bit/J)','SINR','MCS','BLER','Drop','HO','RLF','PRB','PRBuse');

    rows = [];
    names = strings(0);

    % -------------------------------
    % Run baseline first
    % -------------------------------
    baselineExp = expList{1};
    [baseRow, baseMeta] = run_one(cfgBase, baselineExp);
    rows  = [rows; baseRow]; %#ok<AGROW>
    names = [names; string(baselineExp.name)]; %#ok<AGROW>

    % -------------------------------
    % Run other experiments
    % -------------------------------
    for i = 2:numel(expList)
        exp = expList{i};
        [row, ~] = run_one(cfgBase, exp);
        rows  = [rows; row]; %#ok<AGROW>
        names = [names; string(exp.name)]; %#ok<AGROW>
    end

    % -------------------------------
    % Make table
    % -------------------------------
    T = array2table(rows, ...
        'VariableNames', { ...
            'Throughput_Mbps','Energy_J','EnergyEff_bitPerJ', ...
            'MeanSINR_dB','MeanMCS','MeanBLER', ...
            'DropRatio','HOCount','RLFCount', ...
            'MeanPRB','MeanPRBUse'});

    T = addvars(T, names, 'Before', 1, 'NewVariableNames', 'Experiment');

    % Add delta vs baseline
    base = rows(1,:);
    d = rows - base;
    Td = array2table(d, ...
        'VariableNames', { ...
            'dThroughput_Mbps','dEnergy_J','dEnergyEff_bitPerJ', ...
            'dMeanSINR_dB','dMeanMCS','dMeanBLER', ...
            'dDropRatio','dHOCount','dRLFCount', ...
            'dMeanPRB','dMeanPRBUse'});

    T = [T Td];

    % Print final
    for r = 1:height(T)
        fprintf('%-18s %-8.2f %-8.2f %-10.2e %-8.2f %-8.2f %-8.3f %-8.3f %-6d %-6d %-8.0f %-8.2f\n', ...
            T.Experiment(r), ...
            T.Throughput_Mbps(r), ...
            T.Energy_J(r), ...
            T.EnergyEff_bitPerJ(r), ...
            T.MeanSINR_dB(r), ...
            T.MeanMCS(r), ...
            T.MeanBLER(r), ...
            T.DropRatio(r), ...
            round(T.HOCount(r)), ...
            round(T.RLFCount(r)), ...
            T.MeanPRB(r), ...
            T.MeanPRBUse(r));
    end

    fprintf('====================================\n\n');

    result = struct();
    result.table  = T;
    result.matrix = rows;
    result.baseline = baseMeta;
end

% ============================================================
% One run
% ============================================================
function [row, meta] = run_one(cfgBase, exp)

    fprintf('\nRunning: %s\n', exp.name);

    cfg = cfgBase;

    scenario = ScenarioBuilder(cfg);
    ran      = RanKernelNR(cfg, scenario);

    action = RanActionBus.init(cfg);
    action = exp.apply(action, cfg, ran);

    sinrAcc = 0;
    mcsAcc  = 0;
    blerAcc = 0;

    prbAcc    = 0;
    prbUseAcc = 0;

    servedCountAcc = 0;

    for slot = 1:cfg.sim.slotPerEpisode
        ran = ran.step(action);

        ctx = ran.ctx;

        % ---------- SINR ----------
        if isprop(ctx,'sinr_dB') && ~isempty(ctx.sinr_dB)
            sinrAcc = sinrAcc + mean(ctx.sinr_dB);
        end

        % ---------- MCS / BLER from tmp ----------
        if isprop(ctx,'tmp') && isstruct(ctx.tmp)

            if isfield(ctx.tmp,'lastMCSPerUE') && ~isempty(ctx.tmp.lastMCSPerUE)
                % 只统计本slot被调度到的UE，避免大量0拉低平均
                m = ctx.tmp.lastMCSPerUE(:);
                idx = m > 0;
                if any(idx)
                    mcsAcc = mcsAcc + mean(m(idx));
                else
                    mcsAcc = mcsAcc + 0;
                end
            end

            if isfield(ctx.tmp,'lastBLERPerUE') && ~isempty(ctx.tmp.lastBLERPerUE)
                b = ctx.tmp.lastBLERPerUE(:);
                idx = b > 0;
                if any(idx)
                    blerAcc = blerAcc + mean(b(idx));
                else
                    blerAcc = blerAcc + 0;
                end
            end

            if isfield(ctx.tmp,'lastServedBitsPerUE') && ~isempty(ctx.tmp.lastServedBitsPerUE)
                servedCountAcc = servedCountAcc + sum(ctx.tmp.lastServedBitsPerUE(:) > 0);
            end

            if isfield(ctx.tmp,'lastPRBUsedPerCell') && ~isempty(ctx.tmp.lastPRBUsedPerCell) && ctx.numPRB > 0
                prbUseAcc = prbUseAcc + mean(ctx.tmp.lastPRBUsedPerCell(:) ./ ctx.numPRB);
            end
        end

        % ---------- PRB ----------
        if isprop(ctx,'numPRB')
            prbAcc = prbAcc + double(ctx.numPRB);
        end
    end

    report = ran.finalize();
    n = cfg.sim.slotPerEpisode;

    meanSINR = sinrAcc / max(n,1);
    meanMCS  = mcsAcc  / max(n,1);
    meanBLER = blerAcc / max(n,1);

    meanPRB    = prbAcc / max(n,1);
    meanPRBuse = prbUseAcc / max(n,1);

    dropTotal = report.drop_total;
    dropRatio = dropTotal / max(dropTotal + servedCountAcc, 1);

    thr_Mbps = report.throughput_bps_total / 1e6;
    energy_J = report.energy_J_total;

    T = cfg.sim.slotPerEpisode * cfg.sim.slotDuration;
    totalBits = report.throughput_bps_total * T;
    if energy_J > 0
        eff = totalBits / energy_J;
    else
        eff = 0;
    end

    row = [ ...
        thr_Mbps, ...
        energy_J, ...
        eff, ...
        meanSINR, ...
        meanMCS, ...
        meanBLER, ...
        dropRatio, ...
        report.handover_count, ...
        report.rlf_count, ...
        meanPRB, ...
        meanPRBuse];

    meta = struct();
    meta.cfg = cfg;
end


% ============================================================
% Experiment definitions
% ============================================================
function expList = build_experiments(cfg)

    numCell = cfg.scenario.numCell;
    numUE   = cfg.scenario.numUE;

    expList = {};

    % baseline
    expList{end+1} = make_exp("baseline", @(a,c,ran)a);

    % power offset
    expList{end+1} = make_exp("power_-5dB", @(a,c,ran)set_power(a,c,-5));
    expList{end+1} = make_exp("power_+5dB", @(a,c,ran)set_power(a,c,+5));

    % sleep
    expList{end+1} = make_exp("sleep_1_light", @(a,c,ran)set_sleep(a,c,1));
    expList{end+1} = make_exp("sleep_2_deep",  @(a,c,ran)set_sleep(a,c,2));

    % handover knobs
    expList{end+1} = make_exp("hyst_+3dB", @(a,c,ran)set_hyst(a,c,3));
    expList{end+1} = make_exp("hyst_-3dB", @(a,c,ran)set_hyst(a,c,-3));
    expList{end+1} = make_exp("ttt_+5",    @(a,c,ran)set_ttt(a,c,5));
    expList{end+1} = make_exp("ttt_-2",    @(a,c,ran)set_ttt(a,c,-2));

    % bandwidth scale
    expList{end+1} = make_exp("bw_0.5", @(a,c,ran)set_bw(a,c,0.5));
    expList{end+1} = make_exp("bw_0.8", @(a,c,ran)set_bw(a,c,0.8));

    % energy base power scale
    expList{end+1} = make_exp("energy_0.8", @(a,c,ran)set_energy(a,c,0.8));
    expList{end+1} = make_exp("energy_1.1", @(a,c,ran)set_energy(a,c,1.1));

    % interference mitigation flag
    expList{end+1} = make_exp("interfMit_on",  @(a,c,ran)set_interfmit(a,true));
    expList{end+1} = make_exp("interfMit_off", @(a,c,ran)set_interfmit(a,false));

    % rlf threshold offset
    expList{end+1} = make_exp("rlfThr_+3", @(a,c,ran)set_rlf(a,3));
    expList{end+1} = make_exp("rlfThr_-3", @(a,c,ran)set_rlf(a,-3));

    % scheduling: selectedUE boost (choose UE 1 for each cell if possible)
    expList{end+1} = make_exp("sched_selUE", @(a,c,ran)set_selectedUE(a,c,ran));

    % scheduling: weightUE (boost UE1 weight)
    expList{end+1} = make_exp("sched_wUE1x5", @(a,c,ran)set_weightUE(a,c,5));

    % beam: random beam id (just to test wiring)
    expList{end+1} = make_exp("beam_rand", @(a,c,ran)set_beam(a,c,ran));

    % qos priority scaling
    expList{end+1} = make_exp("qos_URLLCx2", @(a,c,ran)set_qos(a,2,1,1));
    expList{end+1} = make_exp("qos_eMBBx2",  @(a,c,ran)set_qos(a,1,2,1));

    % Radio: bandwidthScale expects per cell vector. We keep that.
    % Any new action field can be appended later.

    % ---- nested helpers use cfg sizes ----
    function a = set_power(a,cfg,val)
        a.power.cellTxPowerOffset_dB = val * ones(numCell,1);
    end
    function a = set_sleep(a,cfg,ss)
        a.sleep.cellSleepState = ss * ones(numCell,1);
    end
    function a = set_hyst(a,cfg,val)
        a.handover.hysteresisOffset_dB = val * ones(numCell,1);
    end
    function a = set_ttt(a,cfg,val)
        a.handover.tttOffset_slot = val * ones(numCell,1);
    end
    function a = set_bw(a,cfg,val)
        a.radio.bandwidthScale = val * ones(numCell,1);
    end
    function a = set_energy(a,cfg,val)
        a.energy.basePowerScale = val * ones(numCell,1);
    end
    function a = set_interfmit(a,onoff)
        a.radio.interferenceMitigation = logical(onoff);
    end
    function a = set_rlf(a,val)
        a.rlf.sinrThresholdOffset_dB = val;
    end
    function a = set_selectedUE(a,cfg,ran)
        % pick one UE that currently serves each cell
        % if all UEs in cell 1, we pick UE 1
        a.scheduling.selectedUE = zeros(numCell,1);
        sc = ran.ctx.servingCell;
        for cc = 1:numCell
            u = find(sc == cc, 1, 'first');
            if isempty(u), u = 0; end
            a.scheduling.selectedUE(cc) = u;
        end
    end
    function a = set_weightUE(a,cfg,w)
        a.scheduling.weightUE = ones(numUE,1);
        if numUE >= 1
            a.scheduling.weightUE(1) = w;
        end
    end
    function a = set_beam(a,cfg,ran)
        a.beam.ueBeamId = randi([0,7], numUE, 1);
    end
    function a = set_qos(a,urllc,embb,mmtc)
        a.qos.servicePriority.URLLC = urllc;
        a.qos.servicePriority.eMBB  = embb;
        a.qos.servicePriority.mMTC  = mmtc;
    end
end

function exp = make_exp(name, applyFcn)
    exp = struct();
    exp.name  = name;
    exp.apply = applyFcn;
end
