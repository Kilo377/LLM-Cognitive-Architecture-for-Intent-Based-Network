function rootDir = setup_path()
%SETUP_PATH Add project root and subfolders to MATLAB path

    thisFile = mfilename('fullpath');
    rootDir  = fileparts(thisFile);

    addpath(genpath(rootDir));

    fprintf('[setup] Project root: %s\n', rootDir);
end
