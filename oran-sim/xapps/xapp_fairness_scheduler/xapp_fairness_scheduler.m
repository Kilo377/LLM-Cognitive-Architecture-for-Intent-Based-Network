function action = xapp_fairness_scheduler(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;
    numUE = obs.topology.numUE;

    action = struct();

    servingCell = ones(numUE,1);
    if isfield(obs,'ue') && isfield(obs.ue,'servingCell')
        servingCell = obs.ue.servingCell(:);
    end

    action.scheduling.selectedUE = zeros(numCell,1);

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

    slot = 0;
    if isfield(obs,'meta') && isfield(obs.meta,'slot')
        slot = obs.meta.slot;
    end

    intervalSlots = 5;

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

        [ueBest, ueFair] = selectCandidates(ueIdx, s, b);

        if shouldUseFairness(slot, c, intervalSlots, s, b)
            action.scheduling.selectedUE(c) = ueFair;
        else
            action.scheduling.selectedUE(c) = ueBest;
        end
    end
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

function tf = shouldUseFairness(slot, cellId, intervalSlots, s, b)

    if intervalSlots <= 1
        tf = true;
        return;
    end

    weakMask = getWeakMask(s);
    if ~any(weakMask)
        tf = false;
        return;
    end

    bufMed = median(b) + 1;
    weakBacklog = any(b(weakMask) > bufMed);
    if ~weakBacklog
        tf = false;
        return;
    end

    tf = mod(slot + cellId, intervalSlots) == 0;
end

function [ueBest, ueFair] = selectCandidates(ueIdx, s, b)

    sNorm = normalizeVector(s);
    bNorm = normalizeVector(b);

    [~,kBest] = max(sNorm);
    ueBest = ueIdx(kBest);

    weakMask = getWeakMask(s);
    if any(weakMask)
        scoreFair = 0.7 * (1 - sNorm) + 0.3 * bNorm;
        scoreFair(~weakMask) = -inf;
        [~,kFair] = max(scoreFair);
        ueFair = ueIdx(kFair);
    else
        ueFair = ueBest;
    end
end

function weakMask = getWeakMask(s)

    if isempty(s)
        weakMask = false(size(s));
        return;
    end

    sVal = double(s(:));
    thresh = prctile(sVal, 20);
    weakMask = sVal <= thresh;
end
