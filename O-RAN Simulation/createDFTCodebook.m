function [codebook, beamDirs] = createDFTCodebook(numTxAnt, numBeamsAz, numBeamsEl, elevRangeDeg)
% createDFTCodebook  为均匀平面阵列(UPA)生成 3D 波束码本
%
% [codebook, beamDirs] = createDFTCodebook(numTxAnt, numBeamsAz, numBeamsEl, elevRangeDeg)
%
% 输入：
%   numTxAnt   : gNB.NumTransmitAntennas，总天线数
%   numBeamsAz : 水平方向波束数（覆盖 0~360° 均分）
%   numBeamsEl : 垂直方向波束数（在 elevRangeDeg 均分）
%   elevRangeDeg : [elMin elMax]（单位度），例如 [-60 -3]
%
% 输出：
%   codebook{k} : 1 x numTxAnt 复数行向量，对应第 k 个波束的 precoder
%   beamDirs(k,:) = [azDeg, elDeg]
%
% 约定：
%   - X 轴为水平方向，Z 轴竖直向上
%   - 仰角 el：0° 表示水平，正向上，负向下
%   - 阵列在 X-Z 平面，元素位置 (mx*d, 0, my*d)，mx=0..Nx-1, my=0..Ny-1
%   - 阵元间距 d = λ/2（只影响相位）

if nargin < 4 || isempty(elevRangeDeg)
    elevRangeDeg = [-60 -3];
end

% ===== 阵列尺寸：Nx(水平) x Ny(垂直) =====
% 做一个尽量接近平方的分解 Nx*Ny = numTxAnt
Nx = floor(sqrt(numTxAnt));
while mod(numTxAnt, Nx) ~= 0 && Nx > 1
    Nx = Nx - 1;
end
Ny = numTxAnt / Nx;
assert(Nx*Ny == numTxAnt, "无法将 numTxAnt 分解成 UPA 阵列，请检查天线数。");

% ===== 角度网格 =====
azRange = [0 360];
azVec = linspace(azRange(1), azRange(2), numBeamsAz+1);
azVec(end) = [];   % 去掉 360°，和 0° 重复
elVec = linspace(elevRangeDeg(1), elevRangeDeg(2), numBeamsEl);

numBeamsTot = numBeamsAz * numBeamsEl;

codebook = cell(numBeamsTot, 1);
beamDirs = zeros(numBeamsTot, 2);

% 半波长间距 d = λ/2 => 相位因子里出现 π
d = 0.5;

k = 0;
for iaz = 1:numBeamsAz
    azDeg = azVec(iaz);
    azRad = deg2rad(azDeg);

    for iel = 1:numBeamsEl
        elDeg = elVec(iel);
        elRad = deg2rad(elDeg);

        k = k + 1;
        beamDirs(k,:) = [azDeg, elDeg];

        % 方向余弦：
        %   k = [cos(el)*cos(az), cos(el)*sin(az), sin(el)]
        kx = cos(elRad) * cos(azRad);
        kz = sin(elRad);

        % UPA 元素位置: (mx*d, 0, my*d)
        w = zeros(Nx, Ny);
        for mx = 0:Nx-1
            for my = 0:Ny-1
                % 2π/λ * d = π（d = λ/2）
                phase = pi * (mx * kx + my * kz);
                w(mx+1, my+1) = exp(1j * phase);
            end
        end

        % 展平成 1 x N 行向量，并归一化
        w = w(:).';
        w = w / sqrt(numTxAnt);

        codebook{k} = w;
    end
end
end
