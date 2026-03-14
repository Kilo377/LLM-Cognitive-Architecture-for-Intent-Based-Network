classdef VisualizationManager
%VISUALIZATIONMANAGER Enhanced realtime visualization for ORAN-SIM
%
% New:
% - UE colored by SINR
% - Cell-edge UE highlighted
% - Cell average SINR display
% - Hotspot circle visualization
% - Cleaner scaling

    properties
        fig
        axTopo
        axKPI
        axCell

        kpiTime
        kpiThroughput
        kpiURLLCDrop
    end

    methods
        function obj = VisualizationManager()

            obj.fig = figure('Name','ORAN-SIM Realtime','Color','w');
            tiledlayout(obj.fig,2,2);

            obj.axTopo = nexttile(1);
            title(obj.axTopo,'Topology');
            grid(obj.axTopo,'on'); hold(obj.axTopo,'on');
            axis(obj.axTopo,'equal');
            xlim(obj.axTopo,[-450 450]);
            ylim(obj.axTopo,[-450 450]);

            obj.axKPI = nexttile(2);
            title(obj.axKPI,'System KPI');
            grid(obj.axKPI,'on'); hold(obj.axKPI,'on');

            obj.axCell = nexttile(3,[1 2]);
            title(obj.axCell,'Cell Statistics');
            grid(obj.axCell,'on');

            obj.kpiTime = [];
            obj.kpiThroughput = [];
            obj.kpiURLLCDrop = [];
        end

        function update(obj, state)
            obj.updateTopology(state);
            obj.updateKPI(state);
            obj.updateCell(state);
            drawnow limitrate;
        end
    end

    methods (Access = private)

        %% =========================================================
        % TOPOLOGY
        %% =========================================================
        function updateTopology(obj, state)

            cla(obj.axTopo);

            gNB = state.topology.gNBPos;
            ue  = state.ue.pos;
            sc  = state.ue.servingCell;
            sinr = state.ue.sinr_dB;

            % ---- draw gNB
            scatter(obj.axTopo, gNB(:,1), gNB(:,2), ...
                180,'ks','filled');

            % ---- UE colored by SINR
            scatter(obj.axTopo, ue(:,1), ue(:,2), ...
                50, sinr,'filled');

            colormap(obj.axTopo,'turbo');
            colorbar(obj.axTopo);

            % ---- cell-edge UE (low SINR)
            edgeIdx = sinr < 0;
            scatter(obj.axTopo, ...
                ue(edgeIdx,1), ue(edgeIdx,2), ...
                90,'o','MarkerEdgeColor','k','LineWidth',1.5);

            % ---- high speed UE
            if isfield(state.ue,'speed')
                highIdx = state.ue.speed > 15;
                scatter(obj.axTopo, ...
                    ue(highIdx,1), ue(highIdx,2), ...
                    80,'d','MarkerEdgeColor','r','LineWidth',1.2);
            end

            % ---- connection lines (lighter)
            for u = 1:size(ue,1)
                c = sc(u);
                plot(obj.axTopo, ...
                    [ue(u,1), gNB(c,1)], ...
                    [ue(u,2), gNB(c,2)], ...
                    'Color',[0.85 0.85 0.85]);
            end

            % ---- show per-cell mean SINR
            for c = 1:size(gNB,1)
                idx = sc==c;
                if any(idx)
                    meanSinr = mean(sinr(idx));
                    text(gNB(c,1), gNB(c,2)+30, ...
                        sprintf('%.1f dB',meanSinr), ...
                        'HorizontalAlignment','center', ...
                        'FontWeight','bold');
                end
            end

            xlabel(obj.axTopo,'x (m)');
            ylabel(obj.axTopo,'y (m)');
        end


        %% =========================================================
        % KPI
        %% =========================================================
        function updateKPI(obj, state)

            t = state.time.t_s;

            thr = mean(state.kpi.throughputBitPerUE)/1e6;
            drop = state.kpi.dropURLLC;

            obj.kpiTime(end+1) = t;
            obj.kpiThroughput(end+1) = thr;
            obj.kpiURLLCDrop(end+1) = drop;

            cla(obj.axKPI);

            yyaxis(obj.axKPI,'left');
            plot(obj.axKPI, obj.kpiTime, ...
                obj.kpiThroughput,'LineWidth',1.6);
            ylabel(obj.axKPI,'Throughput (Mbps)');

            yyaxis(obj.axKPI,'right');
            plot(obj.axKPI, obj.kpiTime, ...
                obj.kpiURLLCDrop,'--','LineWidth',1.6);
            ylabel(obj.axKPI,'URLLC Drops');

            xlabel(obj.axKPI,'Time (s)');
        end


        %% =========================================================
        % CELL PANEL
        %% =========================================================
        function updateCell(obj, state)

            cla(obj.axCell);

            prb = state.kpi.prbUtilPerCell;
            numCell = length(prb);

            uePerCell = histcounts( ...
                state.ue.servingCell, ...
                1:(numCell+1));

            meanSinr = zeros(numCell,1);

            for c = 1:numCell
                idx = state.ue.servingCell==c;
                if any(idx)
                    meanSinr(c) = mean(state.ue.sinr_dB(idx));
                end
            end

            X = [prb(:), uePerCell(:), meanSinr(:)];

            bar(obj.axCell, X);

            xlabel(obj.axCell,'Cell ID');
            ylabel(obj.axCell,'Value');

            legend(obj.axCell, ...
                {'PRB Util','UE Count','Mean SINR'});
        end
    end
end