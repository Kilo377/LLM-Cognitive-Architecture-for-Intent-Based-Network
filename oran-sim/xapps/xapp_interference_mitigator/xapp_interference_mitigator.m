function action = xapp_interference_mitigator(input)

    obs = input.measurements;

    numCell = obs.topology.numCell;

    action = struct();

    action.radio.txPowerOffset_dB = -6.0 * ones(numCell,1);
end
