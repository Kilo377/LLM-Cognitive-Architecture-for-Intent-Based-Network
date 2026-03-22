function action = xapp_stability_guard(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;

    action = struct();

    [state, slot] = getState(obs);

    meanBler = getField(obs, "kpi.reliability.meanBLER", 0);
    dropRatio = getField(obs, "kpi.reliability.dropRatio", 0);
    hoCount = getField(obs, "kpi.stability.handoverCount", 0);
    ppCount = getField(obs, "kpi.stability.pingPongCount", 0);
    thr = getField(obs, "kpi.capacity.throughput_Mbps_total", 0);

    updateInterval = 10;
    stepHyst = 1.0;

    if slot >= state.nextUpdate
        dHo = hoCount - state.lastHO;
        dPp = ppCount - state.lastPP;
        dBler = meanBler - state.lastBLER;
        dDrop = dropRatio - state.lastDrop;
        dThr = thr - state.lastThr;

        score = 0;
        if dPp > 1 || dHo > 4
            score = score + 1.5;
        end
        if dBler > 0.001 || dDrop > 0.001
            score = score - 1.0;
        end
        if dThr < 0
            score = score - 0.5;
        end

        if score > 0
            state.hyst = min(state.hyst + stepHyst, 6);
        elseif score < 0
            state.hyst = max(state.hyst - stepHyst, 0);
        end

        state.lastHO = hoCount;
        state.lastPP = ppCount;
        state.lastBLER = meanBler;
        state.lastDrop = dropRatio;
        state.lastThr = thr;
        state.nextUpdate = slot + updateInterval;
    end

    action.handover.hysteresisOffset_dB = state.hyst * ones(numCell,1);

    saveState(state);
end

function [state, slot] = getState(obs)

    slot = 0;
    if isfield(obs,'meta') && isfield(obs.meta,'slot')
        slot = obs.meta.slot;
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
    state.hyst = 2;
    state.lastHO = 0;
    state.lastPP = 0;
    state.lastBLER = 0;
    state.lastDrop = 0;
    state.lastThr = 0;
end


function state = loadState()

    persistent st
    if isempty(st)
        st = initState();
    end
    state = st;
end

function saveState(state)

    persistent st
    st = state;
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
