classdef VisualizationManager
%VISUALIZATIONMANAGER Online visualization for ORAN-SIM

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

            obj.axKPI = nexttile(2);
            title(obj.axKPI,'System KPI');
            grid(obj.axKPI,'on'); hold(obj.axKPI,'on');

            obj.axCell = nexttile(3,[1 2]);
            title(obj.axCell,'Cell PRB Utilization');
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

        function updateTopology(obj, state)
            cla(obj.axTopo);

            gNB = state.topology.gNBPos;
            ue  = state.ue.pos;
            sc  = state.ue.servingCell;

            scatter(obj.axTopo, gNB(:,1), gNB(:,2), 120, 'ks','filled');
            scatter(obj.axTopo, ue(:,1), ue(:,2), 40, sc, 'filled');

            for u = 1:size(ue,1)
                c = sc(u);
                plot(obj.axTopo, ...
                    [ue(u,1), gNB(c,1)], ...
                    [ue(u,2), gNB(c,2)], ...
                    'Color',[0.8 0.8 0.8]);
            end

            xlabel(obj.axTopo,'x (m)');
            ylabel(obj.axTopo,'y (m)');
        end

        function updateKPI(obj, state)
            t = state.time.t_s;

            thr = sum(state.kpi.throughputBitPerUE) / max(t,1e-9);
            drop = state.kpi.dropURLLC;

            obj.kpiTime(end+1) = t;
            obj.kpiThroughput(end+1) = thr / 1e6;
            obj.kpiURLLCDrop(end+1) = drop;

            cla(obj.axKPI);
            yyaxis(obj.axKPI,'left');
            plot(obj.axKPI, obj.kpiTime, obj.kpiThroughput,'LineWidth',1.5);
            ylabel(obj.axKPI,'Throughput (Mbps)');

            yyaxis(obj.axKPI,'right');
            plot(obj.axKPI, obj.kpiTime, obj.kpiURLLCDrop,'--','LineWidth',1.5);
            ylabel(obj.axKPI,'URLLC Drops');

            xlabel(obj.axKPI,'Time (s)');
        end

        function updateCell(obj, state)
            cla(obj.axCell);
            bar(obj.axCell, state.kpi.prbUtilPerCell);
            ylim(obj.axCell,[0 1]);
            xlabel(obj.axCell,'Cell ID');
            ylabel(obj.axCell,'PRB Utilization');
        end
    end
end
