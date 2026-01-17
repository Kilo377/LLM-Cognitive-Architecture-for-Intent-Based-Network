classdef RICBeamScheduler < nrScheduler
% RICBeamScheduler
% 自定义调度器：在 nrScheduler 默认调度的基础上，根据码本为每个
% PDSCH 赋一个 precoding 矩阵 W，实现"码本级 beamforming 控制"。
%
% 用法（在 oranScenarioInit_light 里类似这样用）：
%
%   [codebook, beamDirs] = createDFTCodebook(numTxAnt, numBeams, ...);
%   beamRICFunc          = @(state, K) nearRT_beam_ric(state, K);
%   beamSched            = RICBeamScheduler(codebook, beamRICFunc);
%   beamSched.BeamDirs   = beamDirs;    % 可选：保存一下波束方位信息
%   configureScheduler(gNB, ..., "Scheduler", beamSched);
%
% 注意：
% - 这里只实现"单层传输"：W 尺寸 [1 x NumTransmitAntennas]
% - 如果 BeamRICFunc 返回的 beam index 不合法，会自动做 clip / 回退

    properties
        % Codebook: 1 x K 的 cell，每个元素是 [1 x Ntx] 的复数向量
        Codebook

        % NumBeams: 码本大小 K
        NumBeams

        % BeamRICFunc: 函数句柄 @(state, K) -> beamIdxVec
        %   - state.RNTIList: 本 slot 被调度到的 RNTI 列表（去重后的）
        %   - state.numUEs:   numel(RNTIList)
        %   后续你可以自己在 state 里加更多内容（frame、slot、方位等）
        BeamRICFunc

        % BeamDirs: 可选，用来存每个码本条目对应的方位（比如:
        %   struct('Azimuth', [1xK], 'Elevation', [1xK])
        %   仅仅是元数据，调度时本类当前不会用到，方便你在 RIC 或分析里使用
        BeamDirs
    end

    methods
        function obj = RICBeamScheduler(codebook, beamRICFunc)
            % 构造函数
            %
            % codebook    : cell 数组或数值矩阵（会自动转成 cell）
            % beamRICFunc : 可选，若为空则用简单的 round-robin 选束

            obj@nrScheduler();  % 调用父类构造

            if nargin < 1
                error("RICBeamScheduler:必须至少传入 codebook。");
            end

            % 统一整理成 cell{1,K}，每个元素是 1xNtx 向量
            if iscell(codebook)
                obj.Codebook = codebook;
            else
                % 若是矩阵，假设尺寸为 [Ntx x K] 或 [K x Ntx]
                sz = size(codebook);
                if sz(1) <= sz(2)
                    % 假设：每列一个 beam，[Ntx x K]
                    K = sz(2);
                    cb = cell(1, K);
                    for k = 1:K
                        cb{k} = codebook(:,k).';  % 转成 1xNtx row
                    end
                    obj.Codebook = cb;
                else
                    % 假设：每行一个 beam，[K x Ntx]
                    K = sz(1);
                    cb = cell(1, K);
                    for k = 1:K
                        cb{k} = codebook(k,:);    % 已经是 1xNtx
                    end
                    obj.Codebook = cb;
                end
            end

            obj.NumBeams = numel(obj.Codebook);

            if nargin >= 2
                obj.BeamRICFunc = beamRICFunc;
            else
                obj.BeamRICFunc = [];
            end

            % BeamDirs 由外部可选赋值（例如 oranScenarioInit_light 里）
            obj.BeamDirs = [];
        end
    end

    methods (Access = protected)
        function dlAssignments = scheduleNewTransmissionsDL(obj, timeFrequencyResource, schedulingInfo)
            % 覆写 nrScheduler 的调度入口（下行新传输）
            %
            % 1) 先调用父类拿到默认调度结果 dlAssignments
            % 2) 再根据 codebook / BeamRICFunc 给每个 assignment 写 W

            % 先用内置 scheduler 做完"选哪个 UE、多少 RB"等
            dlAssignments = scheduleNewTransmissionsDL@nrScheduler( ...
                obj, timeFrequencyResource, schedulingInfo);

            % 没有 DL 传输就直接返回
            if isempty(dlAssignments)
                return;
            end

            % === 1) 收集本 slot 被调度到的 RNTI 列表 ===
            rntiList   = [dlAssignments.RNTI];       % 可能有重复
            uniqueRNTI = unique(rntiList, "stable"); % 去重，保持顺序
            numUEs     = numel(uniqueRNTI);

            % === 2) 调用 Beam RIC（如有）生成每个 UE 的 beam index ===
            beamIdxPerUE = [];

            if ~isempty(obj.BeamRICFunc)
                state = struct();
                state.RNTIList = uniqueRNTI;
                state.numUEs   = numUEs;

                % 这里你以后可以扩展：state 里加 frame/slot、UE 位置等

                try
                    beamIdxPerUE = obj.BeamRICFunc(state, obj.NumBeams);
                catch ME
                    warning("RICBeamScheduler: BeamRICFunc 调用失败：%s\n改用 round-robin 选束。", ME.message);
                    beamIdxPerUE = [];
                end
            end

            % 如果 RIC 返回为空或尺寸不对，则用简单的 round-robin
            if isempty(beamIdxPerUE) || numel(beamIdxPerUE) ~= numUEs
                beamIdxPerUE = mod(0:numUEs-1, obj.NumBeams) + 1;  % 1..NumBeams
            else
                beamIdxPerUE = reshape(double(beamIdxPerUE), 1, []);
            end

            % === 3) 构造 RNTI -> beam index 的映射 ===
            rnti2beam = containers.Map("KeyType","double","ValueType","double");
            for i = 1:numUEs
                idx = max(1, min(obj.NumBeams, beamIdxPerUE(i)));  % clip 到合法范围
                rnti2beam(double(uniqueRNTI(i))) = idx;
            end

            % === 4) 取出小区的发射天线数，用来检查/整理 W 的尺寸 ===
            numTx = obj.CellConfig.NumTransmitAntennas;

            % === 5) 给每个 assignment 设置单层 precoder W ===
            for k = 1:numel(dlAssignments)
                rnti = double(dlAssignments(k).RNTI);

                if isKey(rnti2beam, rnti)
                    beamIdx = rnti2beam(rnti);
                else
                    % 理论上不会走到这里，防御性代码
                    beamIdx = mod(rnti-1, obj.NumBeams) + 1;
                end

                wVec = obj.Codebook{beamIdx};

                % 确保是 1 x numTx 的行向量
                wVec = double(wVec); % 防止是 single / gpuArray 等

                if isvector(wVec)
                    wVec = wVec(:).';  % 变成 1xN
                end

                % 如果是其他形状，比如 [Nbeam x Ntx]，简单处理一下
                if size(wVec,1) ~= 1 && size(wVec,2) == numTx
                    % 比如 [Nbeam x Ntx]，取第一行
                    wVec = wVec(1, :);
                elseif size(wVec,2) ~= numTx && size(wVec,1) == numTx
                    % 比如 [Ntx x 1]，转置
                    wVec = wVec.'; % -> 1xNtx
                end

                % 若长度还是对不上，做一次截断 / 填零
                if size(wVec,2) ~= numTx
                    tmp = zeros(1, numTx);
                    nCopy = min(numTx, numel(wVec));
                    tmp(1:nCopy) = wVec(1:nCopy);
                    wVec = tmp;
                end

                % 单层：W = [1 x NumTx]
                dlAssignments(k).W = wVec;
            end
        end
    end
end
