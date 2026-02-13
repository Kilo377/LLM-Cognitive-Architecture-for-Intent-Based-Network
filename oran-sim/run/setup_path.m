function rootDir = setup_path()
%SETUP_PATH Add project root and subfolders to MATLAB path

    % 当前文件所在目录 (run/)
    thisFile = mfilename('fullpath');
    runDir   = fileparts(thisFile);

    % 项目根目录 (run 的上一级)
    rootDir  = fileparts(runDir);

    % 加入整个项目路径
    addpath(genpath(rootDir));

    fprintf('[setup] Project root: %s\n', rootDir);
end
