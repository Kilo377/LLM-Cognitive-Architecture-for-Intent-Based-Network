function action = xapp_throughput_booster(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;
    numUE = obs.topology.numUE;

    action = struct();

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

        score = 0.85 * sNorm + 0.15 * bNorm;

        [~,k] = max(score);
        action.scheduling.selectedUE(c) = ueIdx(k);
    end

    action.beam.mode = "adaptive";
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
