% Compare the wideband SINR for CSI-RS and SRS-based DL measurements in TDD
% system.
%
% Copyright 2024 The MathWorks, Inc.

wirelessnetworkSupportPackageCheck
numUEs = 200; % Total number of UEs in the scenario
x = 0;
% Run the scenario to estimate DL CSI using SRS
srsDLSINR = runScenarios("SRS", numUEs);

% Run the scenario to estimate DL CSI using CSI-RS
csirsDLSINR = runScenarios("CSI-RS", numUEs);

% Extracting PDSCH data from the scheduled slots
csirsDLSINRNonZero = csirsDLSINR(csirsDLSINR~=0);
srsDLSINRNonZero = srsDLSINR(srsDLSINR~=0);

data = {srsDLSINRNonZero(:), csirsDLSINRNonZero(:)};

% Plot the DL SINR CDF for different reference signals
legendName = ["SRS" "CSI-RS"];
xLabel = "SINR (dB)";
figureTitle = "CDF of DL SINR for all UEs";
calculateAndPlotSINRCDF(data, legendName, figureTitle, xLabel);

%% Local functions
function dlSINR = runScenarios(referenceSignal, numUEs)
% The function simulates the scenario for the comparison of the SINRs
    clear displayEventdata; % To clear the persistent variable

    % Create a wireless network simulator.
    rng("default")           % Reset the random number generator
    numFrameSimulation = 50; % Simulation time in terms of number of 10 ms frames
    networkSimulator = wirelessNetworkSimulator.init;

    % Set phyAbstractionType to 'linkToSystemMapping'
    phyAbstractionType = "linkToSystemMapping";

    % Create a gNB node. Specify its position, carrier frequency, channel bandwidth,
    % subcarrier spacing, receive gain, number of transmit and receive antennas, and
    % SRS transmission periodicity (in slots) for all connecting UE nodes
    gNB = nrGNB(Position=[0 0 30],CarrierFrequency=2.6e9,ChannelBandwidth=50e6,SubcarrierSpacing=15e3,DuplexMode="TDD",...
        NumTransmitAntennas=16,NumReceiveAntennas=16,ReceiveGain=11,PHYAbstractionMethod=phyAbstractionType,NumResourceBlocks=200,SRSPeriodicityUE=80);

    % Configure the scheduler to use SRS or CSI-RS based downlink measurement. Set
    % the maximum number of users per TTI to number of UEs to make sure that the
    % every UE gets an opportunity in every slot
    configureScheduler(gNB,CSIMeasurementSignalDL=referenceSignal,MaxNumUsersPerTTI=numUEs)

    uePositions = [(rand(numUEs,1)-0.5)*10000 (rand(numUEs,1)-0.5)*10000 zeros(numUEs,1)] + gNB.Position;
    ueNames = "UE-" + (1:size(uePositions,1));
    % Create 200 UE nodes. Specify the name, the position, the number of transmit
    % antennas, the number of receive antennas, and the receive gain of each UE
    % node.
    UEs = nrUE(Name=ueNames,Position=uePositions,NumTransmitAntennas=4,NumReceiveAntennas=4,ReceiveGain=0,PHYAbstractionMethod=phyAbstractionType);

    % Connect UE nodes to gNB node. Configure full buffer traffic on DL and set CSI
    % report periodicity to 80 slots
    connectUE(gNB,UEs,FullBufferTraffic="DL",CSIReportPeriodicity=80)

    % Add the gNB and UE nodes to the network simulator.
    addNodes(networkSimulator,gNB)
    addNodes(networkSimulator,UEs)

    % Create an N-by-N array of link-level channels, where N represents the number
    % of nodes in the cell. An element at index (i,j) contains the channel instance
    % from node i to node j. If the element at index (i,j) is empty, it indicates
    % the absence of a channel from node i to node j. Here i and j represents the
    % node IDs.
    channelConfig = struct(DelayProfile="CDL-D",DelaySpread=30e-9);
    channels = hNRCreateCDLChannels(channelConfig,gNB,UEs);

    % Create a custom channel model using channels and install the custom
    % channel on the simulator. Network simulator applies the channel to a
    % packet in transit before passing it to the receiver.
    channel = hNRCustomChannelModel(channels,struct(PHYAbstractionMethod=phyAbstractionType));
    addChannelModel(networkSimulator,@channel.applyChannelModel)

    % Register a listener for the 'PacketReceptionEnded' event
    addlistener(UEs,'PacketReceptionEnded', @(src, eventData) displayEventdata(src, eventData, struct(NumUEs=numUEs,SCS=gNB.SubcarrierSpacing)));
    
    % Run the simulation for the specified numFrameSimulation frames
    simulationTime = numFrameSimulation * 1e-2; % Simulation duration (in seconds)
    run(networkSimulator,simulationTime);

    % Extract the DL SINR for the reference signal
    dlSINR = getappdata(0, 'dlsinr');
end

% Extract DL SINR for PDSCH slots
function displayEventdata(~, event, eventInfo)
    persistent dlSINR ueCount scs;
    if isempty(dlSINR)
        dlSINR = [];
        ueCount = zeros(eventInfo.NumUEs, 1);
        scs = eventInfo.SCS;
        setappdata(0, 'dlsinr', dlSINR);
    end
    if strcmp(event.Data.SignalType,"PDSCH") && event.Data.CurrentTime*1e3 > (80/(scs/15e3)) % 80 indicates UE SRS transmission periodicity
        % Extract SINR values for slots greater than 80 as SRS transmissions will be
        % completed for all UEs. Otherwise it will use default rank, precoder and MCS.
        ueCount(event.Data.RNTI, 1) = ueCount(event.Data.RNTI, 1) + 1;
        dlSINR(event.Data.RNTI, ueCount(event.Data.RNTI, 1)) = event.Data.SINR;
        setappdata(0, 'dlsinr', dlSINR);
    end
end

function calculateAndPlotSINRCDF(data, legendName, figureTitle, xLabel)

    % Check if data is not available for plotting
    if all(cellfun(@isempty,data))
        warning("No data available for plotting");
        return;
    end

    fig = figure;
    ax = axes('Parent',fig);
    numPlots = 2;
    for i = 1:numPlots
        % Calculate the empirical cumulative distribution function F, evaluated at
        % x, using the data
        [x, F] = stairs(sort(data{i}),(1:numel(data{i}))/numel(data{i}));
        % Include a starting value, required for accurate plot
        x = [x(1); x];
        F = [0; F];

        % Plot the estimated empirical CDF
        plot(ax,x,F,LineWidth=2);
        hold(ax,"on");
        grid on;
    end
    hold(ax,"off");
    legend(ax,legendName,'Location','best');
    xlabel(ax, xLabel);
    ylabel(ax, 'C.D.F');
    title(ax, figureTitle)
end