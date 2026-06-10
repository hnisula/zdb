const types = @import("common.zig");
const requests = @import("requests.zig");

pub const Initialize = struct {
    const cmd = @tagName(requests.Command.initialize);
    supportsCapabilitiesDoneRequest: ?bool = true,
    supportsFunctionBreakpoints: ?bool = false,
    supportsSetVariable: ?bool = false,
};

pub const SetBreakpoints = struct {
    const cmd = @tagName(requests.Command.setBreakpoints);
    breakpoints: []const Breakpoint,
};

pub const BreakpointReason = enum {
    pending,
    failed,
};

pub const Breakpoint = struct {
    id: ?u32 = null,
    verified: bool,
    message: ?[]const u8 = null,
    source: ?Source = null,
    line: ?u32 = null,
    column: ?u32 = null,
    endLine: ?u32 = null,
    endColumn: ?u32 = null,
    instructionReference: ?[]const u8 = null,
    offset: ?i32 = null,
    reason: ?BreakpointReason = null,
};

// TODO: Fill out and maybe move to types, if shared
pub const Source = struct {};

pub const ConfigurationDone = struct {
    const cmd = @tagName(requests.Command.configurationDone);
};

pub const Launch = struct {
    const cmd = @tagName(requests.Command.launch);
};
