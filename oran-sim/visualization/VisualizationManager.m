classdef VisualizationManager
%VISUALIZATIONMANAGER Online visualization for ORAN-SIM
%
% 功能：
% - 拓扑实时显示
% - UE 轨迹
% - 高速 UE 标记
% - 系统 KPI 曲线
% - 小区 PRB 利用率 + UE 数量
%
% 依赖 state 结构：
% state.topology.gNBPos
% state.ue.pos
% state.ue.servingCell
% state.ue.speed
% state.kpi.*
% state.time.t_s
% 可选:
% state.ext.trajHistory
% state.ext.handoverCount

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

            %% Topology
            obj.axTopo = nexttile(1);
            title(obj.axTopo,'Topology');
            grid(obj.axTopo,'on'); hold(obj.axTopo,'on');
            axis(obj.axTopo,'equal');
            xlim(obj.axTopo,[-450 450]);
            ylim(obj.axTopo,[-450 450]);

            %% KPI
            obj.axKPI = nexttile(2);
            title(obj.axKPI,'System KPI');
            grid(obj.axKPI,'on'); hold(obj.axKPI,'on');

            %% Cell Panel
            obj.axCell = nexttile(3,[1 2]);
            title(obj.axCell,'Cell Load');
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

        %% ===============================
        % Topology 更新
        %% ===============================
        function updateTopology(obj, state)

            cla(obj.axTopo);

            gNB = state.topology.gNBPos;
            ue  = state.ue.pos;
            sc  = state.ue.servingCell;

            % 基站
            scatter(obj.axTopo, gNB(:,1), gNB(:,2), ...
                150,'ks','filled');

            % UE
            scatter(obj.axTopo, ue(:,1), ue(:,2), ...
                40, sc,'filled');

            % 高速 UE 标记
            if isfield(state.ue,'speed')
                highIdx = state.ue.speed > 15;
                scatter(obj.axTopo, ...
                    ue(highIdx,1), ue(highIdx,2), ...
                    80,'o','MarkerEdgeColor','k','LineWidth',1.2);
            end

            % 连接线
            for u = 1:size(ue,1)
                c = sc(u);
                plot(obj.axTopo, ...
                    [ue(u,1), gNB(c,1)], ...
                    [ue(u,2), gNB(c,2)], ...
                    'Color',[0.85 0.85 0.85]);
            end

            % 轨迹
            if isfield(state,'ext') && ...
               isfield(state.ext,'trajHistory')

                for u = 1:length(state.ext.trajHistory)
                    traj = state.ext.trajHistory{u};
                    if size(traj,1) > 2
                        plot(obj.axTopo, ...
                            traj(:,1), traj(:,2), ...
                            'Color',[0.7 0.7 0.7]);
                    end
                end
            end

            % 显示 handover 数
            if isfield(state,'ext') && ...
               isfield(state.ext,'handoverCount')

                title(obj.axTopo, ...
                    sprintf('Topology | Handover = %d', ...
                    state.ext.handoverCount));
            end

            xlabel(obj.axTopo,'x (m)');
            ylabel(obj.axTopo,'y (m)');
        end


        %% ===============================
        % KPI 更新
        %% ===============================
        function updateKPI(obj, state)

            t = state.time.t_s;

            % 使用瞬时平均吞吐
            thr = mean(state.kpi.throughputBitPerUE) / 1e6;
            drop = state.kpi.dropURLLC;

            obj.kpiTime(end+1) = t;
            obj.kpiThroughput(end+1) = thr;
            obj.kpiURLLCDrop(end+1) = drop;

            cla(obj.axKPI);

            yyaxis(obj.axKPI,'left');
            plot(obj.axKPI, obj.kpiTime, ...
                obj.kpiThroughput,'LineWidth',1.5);
            ylabel(obj.axKPI,'Throughput (Mbps)');

            yyaxis(obj.axKPI,'right');
            plot(obj.axKPI, obj.kpiTime, ...
                obj.kpiURLLCDrop,'--','LineWidth',1.5);
            ylabel(obj.axKPI,'URLLC Drops');

            xlabel(obj.axKPI,'Time (s)');
        end


        %% ===============================
        % Cell 面板
        %% ===============================
        function updateCell(obj, state)

            cla(obj.axCell);

            prb = state.kpi.prbUtilPerCell;

            % 每小区 UE 数
            numCell = length(prb);
            uePerCell = histcounts( ...
                state.ue.servingCell, ...
                1:(numCell+1));

            bar(obj.axCell, ...
                [prb(:), uePerCell(:)]);

            ylim(obj.axCell,[0 max(1,max(uePerCell)+1)]);

            xlabel(obj.axCell,'Cell ID');
            ylabel(obj.axCell,'Load / UE Count');

            legend(obj.axCell,{'PRB Util','UE Count'});
        end
    end
end
