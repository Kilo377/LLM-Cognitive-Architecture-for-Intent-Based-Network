function action = xapp_main(input)

    obs = input.measurements;
    cfg = input.config;

    numCell = obs.numCell;
    sel = zeros(numCell,1);

    % ===== 参数（MVP）=====
    D_urgent_slot = 3;
    gamma_dB = 0;

    for c = 1:numCell
        ueSet = find(obs.servingCell == c);
        if isempty(ueSet)
            sel(c) = 0;
            continue;
        end

        dl = obs.minDeadline_slot(ueSet);
        urgentMask = isfinite(dl) & (dl <= D_urgent_slot);
        cand = ueSet(urgentMask);

        if isempty(cand)
            sel(c) = 0;
            continue;
        end

        sinr = obs.sinr_dB(cand);
        good = cand(sinr >= gamma_dB);

        if ~isempty(good)
            cand2 = good;
        else
            cand2 = cand;
        end

        dl2 = obs.minDeadline_slot(cand2);
        [~, idx] = min(dl2);
        u = cand2(idx);

        same = cand2(dl2 == dl2(idx));
        if numel(same) > 1
            urg = obs.urgent_pkts(same);
            [~, k] = max(urg);
            u = same(k);

            same2 = same(urg == urg(k));
            if numel(same2) > 1
                buf = obs.buffer_bits(same2);
                [~, kk] = max(buf);
                u = same2(kk);
            end
        end

        sel(c) = u;
    end

    % ===== 统一 action 输出 =====
    action.control.selectedUE = sel;
    action.metadata.xapp = 'mac_scheduler_urllc';

end
