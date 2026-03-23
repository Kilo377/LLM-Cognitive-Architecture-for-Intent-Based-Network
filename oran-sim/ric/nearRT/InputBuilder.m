function input = InputBuilder(obs, cfg, ctx)
%INPUTBUILDER Build unified input for xApps (MVP)

    input = struct();

    % measurements
    input.measurements = obs;

    % config
    if nargin >= 2 && ~isempty(cfg)
        input.config = cfg;
    else
        input.config = struct();
    end

    % context
    if nargin >= 3 && ~isempty(ctx)
        input.context = ctx;
    else
        input.context = struct();
    end

    % debug
    input.debug = struct();
    input.debug.enableXApp = false;
    if isfield(input.config, "debug") && isfield(input.config.debug, "enableXApp")
        input.debug.enableXApp = logical(input.config.debug.enableXApp);
    end

    % 兜底字段
    if ~isfield(input.context, "time")
        input.context.time = [];
    end

    if ~isfield(input.context, "trigger")
        input.context.trigger = "periodic";
    end

end
