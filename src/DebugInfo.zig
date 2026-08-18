const std = @import("std");
const model = @import("model.zig");
const DwarfInfo = @import("DwarfInfo.zig");

const DebugInfo = @This();

io: std.Io,
gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
dwarf: *DwarfInfo,

units: []model.Unit,
lines: std.ArrayListUnmanaged(model.Line),
sources: std.StringHashMapUnmanaged(model.Source),

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
        .lines = .empty,
        .sources = .empty,
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

fn compareLineAddr(addr: u64, line: model.Line) std.math.Order {
    return std.math.order(addr, line.addr);
}

fn compareLineLessThan(_: void, a: model.Line, b: model.Line) bool {
    return a.addr < b.addr;
}

pub fn lineForAddr(self: *DebugInfo, addr: u64) !?model.Line {
    var index = std.sort.upperBound(model.Line, self.lines.items, addr, compareLineAddr);
    if (index == self.lines.items.len) {
        const new_lines = try self.dwarf.lineRangesForAddr(self.arena.allocator(), addr);
        if (new_lines.len == 0) {
            return null;
        }
        try self.lines.appendSlice(self.arena.allocator(), new_lines);
        std.sort.block(model.Line, self.lines.items, {}, compareLineLessThan);
        index = std.sort.upperBound(model.Line, self.lines.items, addr, compareLineAddr);
    }
    std.debug.assert(index > 0);
    return if (index != self.lines.items.len) return self.lines.items[index - 1] else return null;
}

pub fn addrsForLine(self: *DebugInfo, gpa: std.mem.Allocator, line: model.SourceLoc) []u64 {
    ensureLinesLoaded();
    // TODO: Map addr -> line instead of iterating all lines
    var addrs: std.ArrayList(u64) = .empty;
    for (self.lines.items) |l| {
        if (l.file == line.filepath and l.line == line.line and l.is_stmt) {
            addrs.append(gpa, l.addr);
        }
    }
    return addrs;
}

pub fn ensureLinesLoaded(self: *DebugInfo) !void {
    const new_lines = try self.dwarf.allNonLoadedLines();
    try self.lines.appendSlice(self.arena.allocator(), new_lines);
    std.sort.block(model.Line, self.lines.items, {}, compareLineLessThan);
}

pub fn lineText(self: *DebugInfo, line: *const model.Line) ![]const u8 {
    const a = self.arena.allocator();
    const result = try self.sources.getOrPut(a, line.file);
    if (!result.found_existing) {
        result.value_ptr.*.text = try std.Io.Dir.cwd().readFileAlloc(self.io, line.file, a, .unlimited);
    }
    const source = result.value_ptr.*;
    const line_offset = findLineOffset(source.text, line.line);
    const line_start = line_offset + line.column - 1; // columns are 1-based indices so -1
    const next_line_offset = findNextNewline(source.text, line_start);
    return source.text[line_start..next_line_offset];
}

// Returns std.math.maxInt(64) if line was not found
fn findLineOffset(source: []const u8, line: u64) u64 {
    var it: u64 = 0;
    var line_counter: u64 = 1; // lines are 1-based indices
    while (it <= source.len) {
        if (line_counter == line) {
            return it;
        }
        if (source[it] == '\n') {
            line_counter += 1;
        }
        it += 1;
    }
    return std.math.maxInt(u64);
}

// Returns std.math.maxInt(64) if newline was not found
fn findNextNewline(source: []const u8, cursor: u64) u64 {
    var it: u64 = cursor;
    while (it < source.len) {
        if (source[it] == '\n') {
            return it;
        }
        it += 1;
    }
    return std.math.maxInt(u64);
}
