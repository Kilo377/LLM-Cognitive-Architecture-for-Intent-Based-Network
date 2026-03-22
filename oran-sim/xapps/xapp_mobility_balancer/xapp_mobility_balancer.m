function action = xapp_mobility_balancer(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;

    action = struct();

    [state, slot] = getState(obs);

    thr = getField(obs, "kpi.instant.throughput_Mbps", 0);
    dropRatio = getField(obs, "kpi.instant.dropRatio", 0);
    hoCount = getField(obs, "kpi.stability.handoverCount", 0);
    ppCount = getField(obs, "kpi.stability.pingPongCount", 0);

    state = updateBuffers(state, thr, dropRatio, hoCount, ppCount);

    if state.debugEnable
        fprintf('[DEBUG][slot=%d][xapp_mobility_balancer] preUpdate next=%d samples=%d win=%d thr=%.2f drop=%.4f ho=%d pp=%d\n', ...
            slot, state.nextUpdate, state.sampleCount, state.window, thr, dropRatio, hoCount, ppCount);
    end

    if slot >= state.nextUpdate && state.sampleCount >= state.window
        [winThr, winDrop, winHoRate, winPpRate] = getWindowStats(state);

        reward = computeReward(state, winThr, winDrop, winPpRate);
        state = updateBandit(state, reward, winPpRate);

        [state.hyst, state.ttt] = getActionParams(state, state.actionIdx);

        state.prevWindowThr = winThr;
        state.prevWindowDrop = winDrop;
        state.prevWindowPpRate = winPpRate;
        state.prevWindowHoRate = winHoRate;

        state.nextUpdate = slot + state.updatePeriod;

        if state.debugEnable
            scores = computeScores(state);
            fprintf('[DEBUG][slot=%d][xapp_mobility_balancer] action=%d hyst=%.2f ttt=%d reward=%.4f thr=%.2f drop=%.4f ppRate=%.2f\n', ...
                slot, state.actionIdx, state.hyst, state.ttt, reward, winThr, winDrop, winPpRate);
            fprintf('  counts=%s\n', mat2str(state.counts.'));
            fprintf('  meanReward=%s\n', mat2str(state.meanReward.'));
            fprintf('  scores=%s\n', mat2str(scores.'));
        end
    end

    action.handover.hysteresisOffset_dB = state.hyst * ones(numCell,1);
    action.handover.tttOffset_slot      = state.ttt * ones(numCell,1);

    state = loadState(state);
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

    state.actionIdx = 5;
    state.hyst = 0;
    state.ttt = 0;

    state.actions = [ ...
        -2 -5; ...
        -3 -8; ...
        -4 -10; ...
        -1 -3; ...
         0  0];

    nA = size(state.actions,1);
    state.counts = zeros(nA,1);
    state.meanReward = zeros(nA,1);

    state.alpha = 0.6;

    state.rewardWeightThr = 0.5;
    state.rewardWeightDrop = 1.0;
    state.rewardWeightPp = 0.5;

    state.thrScaleFloor = 50;
    state.dropScaleFloor = 0.01;
    state.ppScaleFloor = 0.1;

    state.ppLimit = 0.2;
    state.ppPenalty = 0.5;
    state.fallbackActionIdx = 4;

    state.bufThr = nan(state.window,1);
    state.bufDrop = nan(state.window,1);
    state.bufHo = nan(state.window,1);
    state.bufPp = nan(state.window,1);
    state.bufPos = 0;
    state.sampleCount = 0;

    state.prevWindowThr = nan;
    state.prevWindowDrop = nan;
    state.prevWindowPpRate = nan;
    state.prevWindowHoRate = nan;

    state.debugEnable = false;
    state.debugEvery = 40;
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

function state = updateBuffers(state, thr, dropRatio, hoCount, ppCount)
    pos = state.bufPos + 1;
    if pos > state.window
        pos = 1;
    end
    state.bufPos = pos;

    state.bufThr(pos) = thr;
    state.bufDrop(pos) = dropRatio;
    state.bufHo(pos) = hoCount;
    state.bufPp(pos) = ppCount;

    state.sampleCount = min(state.sampleCount + 1, state.window);
end

function [winThr, winDrop, winHoRate, winPpRate] = getWindowStats(state)
    order = [state.bufPos+1:state.window, 1:state.bufPos];
    if isempty(order)
        winThr = nan; winDrop = nan; winHoRate = nan; winPpRate = nan;
        return;
    end

    valsThr = state.bufThr(order);
    valsDrop = state.bufDrop(order);
    valsHo = state.bufHo(order);
    valsPp = state.bufPp(order);

    valsThr = valsThr(~isnan(valsThr));
    valsDrop = valsDrop(~isnan(valsDrop));
    valsHo = valsHo(~isnan(valsHo));
    valsPp = valsPp(~isnan(valsPp));

    winThr = mean(valsThr, 'omitnan');
    winDrop = mean(valsDrop, 'omitnan');

    if numel(valsHo) >= 2
        winHoRate = (valsHo(end) - valsHo(1)) / max(numel(valsHo)-1,1);
    else
        winHoRate = 0;
    end

    if numel(valsPp) >= 2
        winPpRate = (valsPp(end) - valsPp(1)) / max(numel(valsPp)-1,1);
    else
        winPpRate = 0;
    end
end

function reward = computeReward(state, winThr, winDrop, winPpRate)
    if isnan(state.prevWindowThr) || isnan(state.prevWindowDrop) || isnan(state.prevWindowPpRate)
        reward = 0;
        return;
    end

    dThr = (winThr - state.prevWindowThr) / max(abs(state.prevWindowThr), state.thrScaleFloor);
    dDrop = (winDrop - state.prevWindowDrop) / max(abs(state.prevWindowDrop), state.dropScaleFloor);
    dPp = (winPpRate - state.prevWindowPpRate) / max(abs(state.prevWindowPpRate), state.ppScaleFloor);

    reward = state.rewardWeightThr * dThr - state.rewardWeightDrop * dDrop - state.rewardWeightPp * dPp;

    if winPpRate > state.ppLimit
        reward = reward - state.ppPenalty;
    end
end

function state = updateBandit(state, reward, winPpRate)
    idx = state.actionIdx;
    state.counts(idx) = state.counts(idx) + 1;
    c = state.counts(idx);
    state.meanReward(idx) = state.meanReward(idx) + (reward - state.meanReward(idx)) / c;

    state.actionIdx = selectAction(state);

    if winPpRate > state.ppLimit
        state.actionIdx = state.fallbackActionIdx;
    end
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

function scores = computeScores(state)
    scores = zeros(size(state.counts));
    if any(state.counts == 0)
        return;
    end
    total = sum(state.counts);
    scores = state.meanReward + state.alpha * sqrt(log(max(total,1)) ./ state.counts);
end

function [hyst, ttt] = getActionParams(state, idx)
    if idx < 1 || idx > size(state.actions,1)
        idx = 1;
    end
    hyst = state.actions(idx,1);
    ttt  = state.actions(idx,2);
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
