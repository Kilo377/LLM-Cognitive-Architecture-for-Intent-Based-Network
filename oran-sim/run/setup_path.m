function rootDir = setup_path()

    % 当前文件在 run 目录
    runDir = fileparts(mfilename('fullpath'));

    % 上一级才是项目根目录
    rootDir = fileparts(runDir);

    addpath(genpath(rootDir));

end
