function action = xapp_drop_reducer(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;
    numUE = obs.topology.numUE;

    action = struct();

    [state, slot] = getState(obs);

    servingCell = ones(numUE,1);
    if isfield(obs,'ue') && isfield(obs.ue,'servingCell')
        servingCell = obs.ue.servingCell(:);
    end

    sinr = zeros(numUE,1);
    if isfield(obs,'ue') && isfield(obs.ue,'sinr_dB')
        sinr = double(obs.ue.sinr_dB(:));
    end

    cqi = zeros(numUE,1);
    if isfield(obs,'ue') && isfield(obs.ue,'cqi')
        cqi = double(obs.ue.cqi(:));
    end

    bufferBits = zeros(numUE,1);
    if isfield(obs,'ue') && isfield(obs.ue,'buffer_bits')
        bufferBits = double(obs.ue.buffer_bits(:));
    end

    thr = getField(obs, "kpi.instant.throughput_Mbps", 0);
    dropRatio = getField(obs, "kpi.instant.dropRatio", 0);
    meanBler = getField(obs, "kpi.instant.meanBLER", 0);

    state = updateBuffers(state, thr, dropRatio, meanBler);

    if slot >= state.nextUpdate && state.sampleCount >= state.window
        [winThr, winDrop, winBler] = getWindowStats(state);

        state = maybeInitBaseline(state, winDrop, winBler);
        reward = computeReward(state, winThr, winDrop, winBler);
        state = updateBandit(state, reward);

        state.prevWindowThr = winThr;
        state.prevWindowDrop = winDrop;
        state.prevWindowBler = winBler;
        state.nextUpdate = slot + state.updatePeriod;

        if state.debugEnable
            fprintf('[DEBUG][slot=%d][xapp_drop_reducer] action=%d reward=%.4f thr=%.2f drop=%.4f bler=%.4f\n', ...
                slot, state.actionIdx, reward, winThr, winDrop, winBler);
        end
    end

    weights = state.actions(state.actionIdx,:);

    action.scheduling.selectedUE = zeros(numCell,1);

    for c = 1:numCell
        ueIdx = find(servingCell == c);
        if isempty(ueIdx)
            continue;
        end

        s = sinr(ueIdx);
        if all(s == 0)
            s = cqi(ueIdx);
        end
        b = bufferBits(ueIdx);

        sNorm = normalizeVector(s);
        bNorm = normalizeVector(b);

        score = weights(1) * sNorm + weights(2) * bNorm;

        [~,k] = max(score);
        action.scheduling.selectedUE(c) = ueIdx(k);
    end

    state = loadState(state);
end

function out = normalizeVector(x)

    x = double(x(:));
    if isempty(x)
        out = x;
        return;
    end

    xMin = min(x);
    xMax = max(x);
    if xMax - xMin < eps
        out = zeros(size(x));
        return;
    end

    out = (x - xMin) / (xMax - xMin);
end

function [state, slot] = getState(obs)

    slot = 0;
    if isfield(obs,'time') && isfield(obs.time,'slot')
        slot = obs.time.slot;
    end

    state = loadState();

    if slot < state.lastSlot
        state = initState();
    end
    state.lastSlot = slot;
end

function state = initState()

    state = struct();
    state.lastSlot = 0;
    state.nextUpdate = 0;

    state.window = 20;
    state.updatePeriod = 40;

    % action weights: [sinrWeight bufferWeight]
    state.actions = [ ...
        0.4 0.6; ...
        0.2 0.8];

    state.actionIdx = 1;
    nA = size(state.actions,1);
    state.counts = zeros(nA,1);
    state.meanReward = zeros(nA,1);
    state.alpha = 0.6;

    state.bufThr = nan(state.window,1);
    state.bufDrop = nan(state.window,1);
    state.bufBler = nan(state.window,1);
    state.bufPos = 0;
    state.sampleCount = 0;

    state.prevWindowThr = nan;
    state.prevWindowDrop = nan;
    state.prevWindowBler = nan;

    state.baselineDrop = nan;
    state.baselineBler = nan;

    state.dropCapFactor = 1.2;
    state.blerCapFactor = 1.2;

    state.debugEnable = false;
end

function state = loadState(newState)

    persistent st
    if isempty(st)
        st = initState();
    end
    if nargin > 0
        st = newState;
    end
    state = st;
end

function state = updateBuffers(state, thr, dropRatio, meanBler)
    pos = state.bufPos + 1;
    if pos > state.window
        pos = 1;
    end
    state.bufPos = pos;

    state.bufThr(pos) = thr;
    state.bufDrop(pos) = dropRatio;
    state.bufBler(pos) = meanBler;

    state.sampleCount = min(state.sampleCount + 1, state.window);
end

function [winThr, winDrop, winBler] = getWindowStats(state)
    order = [state.bufPos+1:state.window, 1:state.bufPos];
    if isempty(order)
        winThr = nan; winDrop = nan; winBler = nan;
        return;
    end

    valsThr = state.bufThr(order);
    valsDrop = state.bufDrop(order);
    valsBler = state.bufBler(order);

    winThr = mean(valsThr, 'omitnan');
    winDrop = mean(valsDrop, 'omitnan');
    winBler = mean(valsBler, 'omitnan');
end

function state = maybeInitBaseline(state, winDrop, winBler)
    if isnan(state.baselineDrop) && ~isnan(winDrop)
        state.baselineDrop = winDrop;
    end
    if isnan(state.baselineBler) && ~isnan(winBler)
        state.baselineBler = winBler;
    end
end

function reward = computeReward(state, winThr, winDrop, winBler)
    if isnan(state.prevWindowThr)
        reward = 0;
        return;
    end

    dThr = winThr - state.prevWindowThr;

    dropCap = max(state.baselineDrop * state.dropCapFactor, 0.01);
    blerCap = max(state.baselineBler * state.blerCapFactor, 0.01);

    dropPenalty = max(0, winDrop - dropCap);
    blerPenalty = max(0, winBler - blerCap);

    reward = dThr - dropPenalty - blerPenalty;
end

function state = updateBandit(state, reward)
    idx = state.actionIdx;
    state.counts(idx) = state.counts(idx) + 1;
    c = state.counts(idx);
    state.meanReward(idx) = state.meanReward(idx) + (reward - state.meanReward(idx)) / c;

    state.actionIdx = selectAction(state);
end

function idx = selectAction(state)
    zeroIdx = find(state.counts == 0, 1);
    if ~isempty(zeroIdx)
        idx = zeroIdx;
        return;
    end

    total = sum(state.counts);
    scores = state.meanReward + state.alpha * sqrt(log(max(total,1)) ./ state.counts);
    [~, idx] = max(scores);
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
    else
        v = defaultValue;
    end
end
