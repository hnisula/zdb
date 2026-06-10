pub const Command = enum {
    configurationDone,
    initialize,
    launch,
    setBreakpoints,
};

pub const Request = union(Command) {
    configurationDone: ConfigurationDone,
    initialize: Initialize,
    launch: Launch,
    setBreakpoints: SetBreakpoints,
};

pub const Initialize = struct {
    const cmd = @tagName(Command.initialize);
    client_id: []const u8,
    adapter_id: []const u8,
};

pub const SetBreakpoints = struct {
    const cmd = @tagName(Command.setBreakpoints);
    source: []const u8,
    breakpoints: ?[]SourceBreakpoint = null,
    sourceModified: ?bool = null,
};

pub const SourceBreakpoint = struct {
    line: []const u8,
    column: ?[]const u8 = null,
    condition: ?[]const u8 = null,
    hitCondition: ?[]const u8 = null,
    logMessage: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

pub const ConfigurationDone = struct {
    const cmd = @tagName(Command.configurationDone);
};

pub const Launch = struct {
    const cmd = @tagName(Command.launch);
    noDebug: ?bool = null,
};
