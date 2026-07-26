const std = @import("std");
const model = @import("model.zig");
const DwarfInfo = @import("DwarfInfo.zig");

const DebugInfo = @This();

io: std.Io,
gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
dwarf: *DwarfInfo,

units: []model.Unit,
lines: []model.Line,

pub fn init(io: std.Io, gpa: std.mem.Allocator, exe_path: []const u8) !DebugInfo {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var dwarf = try arena.allocator().create(DwarfInfo);
    dwarf.* = try .init(io, gpa, exe_path);
    errdefer dwarf.deinit();

    const units = try dwarf.getUnits(arena.allocator());

    return .{
        .io = io,
        .gpa = gpa,
        .arena = arena,
        .dwarf = dwarf,
        .units = units,
        .lines = &.{},
    };
}

pub fn deinit(self: *DebugInfo) void {
    self.dwarf.deinit();
    self.arena.deinit();
}

pub fn getUnit(self: *DebugInfo, addr: u64) ?model.Unit {
    for (self.units) |unit| {
        for (unit.ranges) |range| {
            if (range.low <= addr and addr <= range.high) {
                return unit;
            }
        }
    }
    return null;
}

fn compareLine(addr: u64, line: model.Line) std.math.Order {
    return std.math.order(addr, line.addr);
}

pub fn getLine(self: *DebugInfo, addr: u64) !?model.Line {
    const index = std.sort.upperBound(model.Line, self.lines, addr, compareLine);
    if (index == self.lines.len) {
        const line_ranges = try self.dwarf.getLineRanges(self.arena.allocator(), addr);
        _ = line_ranges;
        // TODO: If no lines: return error
    }
    return null;
}
