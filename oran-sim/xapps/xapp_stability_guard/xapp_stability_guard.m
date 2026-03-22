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

    if state.debugEnable
        fprintf('[DEBUG][slot=%d][xapp_stability_guard] preUpdate next=%d hyst=%.2f ho=%d pp=%d drop=%.4f bler=%.4f thr=%.2f\n', ...
            slot, state.nextUpdate, state.hyst, hoCount, ppCount, dropRatio, meanBler, thr);
    end

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

        if state.debugEnable
            fprintf('[DEBUG][slot=%d][xapp_stability_guard] score=%.2f hyst=%.2f dHo=%d dPp=%d dDrop=%.4f dBler=%.4f dThr=%.2f\n', ...
                slot, score, state.hyst, dHo, dPp, dDrop, dBler, dThr);
        end
    end

    action.handover.hysteresisOffset_dB = state.hyst * ones(numCell,1);

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
    state.hyst = 2;
    state.lastHO = 0;
    state.lastPP = 0;
    state.lastBLER = 0;
    state.lastDrop = 0;
    state.lastThr = 0;

    state.debugEnable = true;
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
