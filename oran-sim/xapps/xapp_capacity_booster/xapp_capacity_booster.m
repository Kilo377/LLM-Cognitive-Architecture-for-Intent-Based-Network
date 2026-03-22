function action = xapp_capacity_booster(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;

    action = struct();

    action.radio.txPowerOffset_dB = 3.0 * ones(numCell,1);
    action.radio.bandwidthScale   = 1.5 * ones(numCell,1);
end
