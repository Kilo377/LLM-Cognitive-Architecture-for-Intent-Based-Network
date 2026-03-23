function action = xapp_fairness_no_drop_loss(input)

    obs = input.measurements;
    action = struct();

    [state, slot] = getState(obs);

    if isfield(input,'debug') && isfield(input.debug,'enableXApp')
        state.debugEnable = logical(input.debug.enableXApp);
    end

    if ~state.baselineLoaded
        state.baselineDrop = readBaselineValue('dropRatio');
        state.baselineLoaded = true;
    end

    dropRatio = getField(obs, "kpi.reliability.dropRatio", nan);
    state = updateBuffer(state, dropRatio);

    if slot >= state.nextUpdate && state.sampleCount >= state.window
        winDrop = mean(state.buf, 'omitnan');

        if winDrop > state.baselineDrop * (1 + state.dropRiseCap)
            state.weightUE = ones(state.numUE,1);
            state.lastDecision = "guarded";
        else
            state.weightUE = computeFairWeights(obs, state.weightAmp);
            state.lastDecision = "fairness";
        end

        state.nextUpdate = slot + state.updatePeriod;

        if state.debugEnable
            fprintf('[DEBUG][slot=%d][xapp_fairness_no_drop_loss] dropW=%.4f base=%.4f decision=%s\n', ...
                slot, winDrop, state.baselineDrop, state.lastDecision);
        end
    end

    action.scheduling.weightUE = state.weightUE;

    state = loadState(state);
end

function w = computeFairWeights(obs, weightAmp)

    numUE = obs.topology.numUE;
    t_s = 0;
    if isfield(obs,'time') && isfield(obs.time,'t_s')
        t_s = double(obs.time.t_s);
    end

    thrPerUE = zeros(numUE,1);
    if isfield(obs,'kpi') && isfield(obs.kpi,'throughputBitPerUE')
        bits = double(obs.kpi.throughputBitPerUE(:));
        if t_s > 0
            thrPerUE = bits / t_s / 1e6;
        end
    end

    meanThr = mean(thrPerUE);
    deficit = max(0, meanThr - thrPerUE);
    if max(deficit) > 0
        deficit = deficit / max(deficit);
    else
        deficit = zeros(numUE,1);
    end

    w = 1 + weightAmp * deficit;
    w = min(max(w,0),10);
end

function [state, slot] = getState(obs)

    slot = 0;
    if isfield(obs,'time') && isfield(obs.time,'slot')
        slot = obs.time.slot;
    end

    state = loadState();

    if slot < state.lastSlot
        state = initState(obs);
    end
    state.lastSlot = slot;
end

function state = initState(obs)

    numUE = obs.topology.numUE;

    state = struct();
    state.numUE = numUE;
    state.lastSlot = 0;
    state.nextUpdate = 0;

    state.window = 20;
    state.updatePeriod = 20;
    state.dropRiseCap = 0.05;
    state.weightAmp = 0.4;

    state.buf = nan(state.window,1);
    state.bufPos = 0;
    state.sampleCount = 0;

    state.weightUE = ones(numUE,1);
    state.lastDecision = "init";

    state.baselineDrop = nan;
    state.baselineLoaded = false;

    state.debugEnable = false;
end

function state = loadState(newState)

    persistent st
    if isempty(st)
        st = initState(struct('topology', struct('numUE', 1)));
    end
    if nargin > 0
        st = newState;
    end
    state = st;
end

function state = updateBuffer(state, value)

    pos = state.bufPos + 1;
    if pos > state.window
        pos = 1;
    end
    state.bufPos = pos;

    state.buf(pos) = value;
    state.sampleCount = min(state.sampleCount + 1, state.window);
end

function v = readBaselineValue(metricName)

    baseDir = fileparts(mfilename('fullpath'));
    csvPath = fullfile(baseDir, 'baseline.csv');

    if ~isfile(csvPath)
        error('xapp_fairness_no_drop_loss:MissingBaseline', ...
            'baseline.csv not found at %s', csvPath);
    end

    tbl = readtable(csvPath, 'Delimiter', ',', 'ReadVariableNames', true);
    varNames = lower(string(tbl.Properties.VariableNames));
    idxMetric = find(varNames == "metric", 1);
    idxValue = find(varNames == "value", 1);
    if isempty(idxMetric) || isempty(idxValue)
        error('xapp_fairness_no_drop_loss:BaselineFormat', ...
            'baseline.csv must have columns: metric,value');
    end

    metrics = string(tbl{:, idxMetric});
    vals = tbl{:, idxValue};
    if isempty(metrics)
        error('xapp_fairness_no_drop_loss:BaselineEmpty', 'baseline.csv is empty');
    end

    idx = find(lower(metrics) == lower(string(metricName)), 1);
    if isempty(idx)
        error('xapp_fairness_no_drop_loss:BaselineMissingMetric', ...
            'baseline.csv missing metric %s', metricName);
    end

    v = vals(idx);
    if isempty(v) || ~isnumeric(v) || ~isscalar(v) || ~isfinite(v) || v <= 0
        error('xapp_fairness_no_drop_loss:BaselineInvalidValue', ...
            'baseline.csv metric %s must be a positive scalar', metricName);
    end
end

function v = getField(s, path, defaultValue)

    v = defaultValue;
    if ~isstruct(s)
        return;
    end

    parts = split(string(path), ".");
    parts = cellstr(parts);
    cur = s;
    for i = 1:numel(parts)
        key = parts{i};
        if ~isfield(cur, key)
            return;
        end
        cur = cur.(key);
    end

    if isempty(cur)
        return;
    end

    if isnumeric(cur)
        if isscalar(cur)
            v = double(cur);
        else
            v = double(cur(1));
        end
    end
end
