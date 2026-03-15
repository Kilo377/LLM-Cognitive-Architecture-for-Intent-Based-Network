function action = xapp_load_balancing(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;
    numUE   = obs.topology.numUE;

    action = struct();

    jain = 1.0;
    top10 = 0;
    if isfield(obs,'kpi') && isfield(obs.kpi,'capacity')
        if isfield(obs.kpi.capacity,'jainFairness')
            jain = double(obs.kpi.capacity.jainFairness);
        end
        if isfield(obs.kpi.capacity,'top10Share')
            top10 = double(obs.kpi.capacity.top10Share);
        end
    end

    servingCell = ones(numUE,1);
    bufferBits = zeros(numUE,1);

    if isfield(obs,'ue')
        if isfield(obs.ue,'servingCell')
            servingCell = obs.ue.servingCell(:);
        end
        if isfield(obs.ue,'buffer_bits')
            bufferBits = double(obs.ue.buffer_bits(:));
        end
    end

    bufMed = median(bufferBits) + 1;
    bufMax = max(bufferBits);

    trigger = false;
    if jain < 0.90 || top10 > 0.20
        trigger = true;
    end
    if bufMax > 2.0 * bufMed
        trigger = true;
    end

    debugEnable = false;
    if isfield(input,'config') && isfield(input.config,'debug') && ...
            isfield(input.config.debug,'enable') && input.config.debug.enable
        debugEnable = true;
        if isfield(input.config.debug,'modules')
            try
                mods = string(input.config.debug.modules);
                debugEnable = any(mods=="xapp_load_balancing") || any(mods=="xapp") || any(mods=="all");
            catch
            end
        end
    end

    if ~trigger
        if debugEnable
            slot = 0;
            if isfield(obs,'meta') && isfield(obs.meta,'slot')
                slot = obs.meta.slot;
            end
            fprintf('[xapp_load_balancing][slot=%d] no-trigger jain=%.3f top10=%.3f bufMax=%.2e bufMed=%.2e\n', ...
                slot, jain, top10, bufMax, bufMed);
        end
        return;
    end

    action.scheduling.selectedUE = zeros(numCell,1);
    action.scheduling.weightUE   = ones(numUE,1);

    for c = 1:numCell
        ueIdx = find(servingCell == c);
        if isempty(ueIdx)
            continue;
        end

        b = bufferBits(ueIdx);
        bNorm = b / (median(b) + 1);
        [~,k] = max(b);
        action.scheduling.selectedUE(c) = ueIdx(k);

        w = 0.6 + 0.8 * min(bNorm,4);
        action.scheduling.weightUE(ueIdx) = w;
    end

    if debugEnable
        slot = 0;
        if isfield(obs,'meta') && isfield(obs.meta,'slot')
            slot = obs.meta.slot;
        end
        maxW = max(action.scheduling.weightUE);
        selCount = sum(action.scheduling.selectedUE > 0);
        fprintf('[xapp_load_balancing][slot=%d] trigger jain=%.3f top10=%.3f bufMax=%.2e bufMed=%.2e sel=%d maxW=%.2f\n', ...
            slot, jain, top10, bufMax, bufMed, selCount, maxW);
    end
end
