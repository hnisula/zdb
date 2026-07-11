const std = @import("std");
const builtin = @import("builtin");
const DwarfInfo = @This();

elf: std.debug.ElfFile,
gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,

const InitError = error{
    NoDwarf,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, binary_path: []const u8) !DwarfInfo {
    const arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const bin_file = try std.Io.Dir.cwd().openFile(io, binary_path, .{});
    defer bin_file.close(io);
    var elf: std.debug.ElfFile = try .load(gpa, io, bin_file, null, &.none);
    errdefer elf.deinit(gpa);
    const dwarf = if (elf.dwarf) |*dwarf| dwarf else {
        return error.NoDwarf;
    };
    try dwarf.open(gpa, builtin.cpu.arch.endian());
    var dwarf_info: DwarfInfo = .{ .elf = elf, .gpa = gpa, .arena = arena };

    const abbrev_section = dwarf.sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_abbrev)].?.data;
    var abbrev_offset: u64 = 0;
    const abbrevs = try dwarf_info.readAbbrevs(abbrev_section, &abbrev_offset);

    // TODO: Parse DIEs and build a hierarchy and map
    const dies = dwarf.sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_info)].?.data;
    var offset: usize = 0;

    while (dies.len > offset) {
        const cu_offset = offset;
        const cu = try dwarf_info.readCu(&abbrevs, dies, &offset);
        std.debug.print("CU tag: {d}\nCU size: {d}\n", .{ cu.die.tag, cu.header.unit_len });

        offset = cu_offset + cu.header.unit_len;
    }

    return dwarf_info;
}

pub fn deinit(self: *DwarfInfo) void {
    self.elf.deinit(self.gpa);
    self.arena.deinit();
}

fn getSection(self: *DwarfInfo, id: std.debug.Dwarf.Section.Id) []const u8 {
    return self.elf.dwarf.?.sections[@intFromEnum(id)].?.data;
}

fn readBytes(n: u8, data: []const u8, offset: *usize) u64 {
    const value = std.mem.readVarInt(u64, data[offset.*..][0..n], builtin.cpu.arch.endian());
    offset.* += n;
    return value;
}

fn readSleb128(data: []const u8, offset: *usize) i64 {
    var value: i64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = data[offset.*];
        value |= @as(i64, byte & 0x7f) << shift;
        offset.* += 1;
        shift += 7;
        if (byte & 0x80 == 0) {
            return value;
        }
    }
}

fn readUleb128(data: []const u8, offset: *usize) u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = data[offset.*];
        value |= @as(u64, byte & 0x7f) << shift;
        offset.* += 1;
        shift += 7;
        if (byte & 0x80 == 0) {
            return value;
        }
    }
}

fn readStrp(data: []const u8, offset: *usize, dwarf: *std.debug.Dwarf, section_id: std.debug.Dwarf.Section.Id) []const u8 {
    const str_offset = readBytes(4, data, offset);
    return std.mem.sliceTo(dwarf.sections[@intFromEnum(section_id)].?.data[str_offset..], 0);
}

fn readBlock(size: u64, data: []const u8, offset: *usize) []const u8 {
    offset.* += size;
    return data[offset.*..][0..size];
}

const AbbrevAttr = struct {
    attr: u64,
    form: u64,
    implicit_const: i64,
};

const Abbrev = struct {
    code: u64,
    tag: u64,
    has_children: bool,
    attributes: []const AbbrevAttr,
};

const CuHeader = struct {
    offset: u64,
    dwarf_format: u8, // Dwarf format (32 or 64 bit) in bytes (4 or 8)
    len: u64,
    unit_len: u64,
    version: u16,
    unit_type: u8,
    addr_size: u8,
    debug_abbrev_offset: u32,
};

const CompileUnit = struct {
    name: []const u8,
    has_children: bool,
};

fn readAbbrevEntry(self: *DwarfInfo, scratch: *std.ArrayList(AbbrevAttr), data: []const u8, offset: *usize) !Abbrev {
    const code = readUleb128(data, offset);
    if (code == 0) {
        return .{ .code = code, .tag = 0, .has_children = false, .attributes = &.{} };
    }
    const tag = readUleb128(data, offset);
    const has_children = data[offset.*] != 0;
    offset.* += 1;
    _ = std.dwarf.TAG.imported_declaration;

    while (true) {
        const attr = readUleb128(data, offset);
        const form = readUleb128(data, offset);
        var implicit_const: i64 = 0;
        if (attr == 0 and form == 0) {
            break;
        }
        if (form == std.dwarf.FORM.implicit_const) {
            implicit_const = readSleb128(data, offset);
        }
        try scratch.append(self.gpa, .{ .attr = attr, .form = form, .implicit_const = implicit_const });
    }

    var attrs: []AbbrevAttr = undefined;

    if (scratch.items.len > 0) {
        attrs = try self.arena.allocator().alloc(AbbrevAttr, scratch.items.len);
        @memcpy(attrs, scratch.items);
        scratch.clearRetainingCapacity();
    } else {
        attrs = &.{};
    }

    return .{ .code = code, .tag = tag, .has_children = has_children, .attributes = attrs };
}

fn readAbbrevs(self: *DwarfInfo, data: []const u8, offset: *usize) !std.AutoHashMap(u64, Abbrev) {
    const arena = self.arena.allocator();
    var attr_scratch: std.ArrayList(AbbrevAttr) = try .initCapacity(self.gpa, 36);
    defer attr_scratch.deinit(self.gpa);
    var map: std.AutoHashMap(u64, Abbrev) = .init(arena);
    while (true) {
        const abbrev = try self.readAbbrevEntry(&attr_scratch, data, offset);
        if (abbrev.code == 0) {
            break;
        }
        try map.put(abbrev.code, abbrev);
    }
    return map;
}

fn readCuHeader(data: []const u8, offset: *usize) CuHeader {
    const endian = builtin.cpu.arch.endian();
    const header_start = offset.*;
    var unit_len: u64 = @intCast(std.mem.readInt(u32, data[offset.*..][0..4], endian));
    var len_size: u8 = 4;
    var format: u8 = 4;
    offset.* += 4;
    var header_len: u64 = 4 + 2 + 1 + 1 + 4;
    if (unit_len == std.math.maxInt(u32)) {
        unit_len = std.mem.readInt(u64, data[offset.*..][0..8], endian);
        offset.* += 8;
        header_len += 8;
        len_size += 8;
        format = 8;
    }
    const version = std.mem.readInt(u16, data[offset.*..][0..2], endian);
    const unit_type = data[offset.* + 2];
    const addr_size = data[offset.* + 3];
    const debug_abbrev_offset = std.mem.readInt(u32, data[offset.* + 4 ..][0..4], endian);
    offset.* += 2 + 1 + 1 + 4;
    return .{
        .offset = header_start,
        .dwarf_format = format,
        .len = header_len,
        .unit_len = unit_len + len_size,
        .version = version,
        .unit_type = unit_type,
        .addr_size = addr_size,
        .debug_abbrev_offset = debug_abbrev_offset,
    };
}

const dw_tag = std.dwarf.TAG;
const DieType = enum(u32) {
    compile_unit = dw_tag.compile_unit,
    module = dw_tag.module,
    subprogram = dw_tag.subprogram,
};

const ParseContext = struct {
    die_scratch: std.ArrayList(Die),
    attr_scratch: std.ArrayList(Attribute),
    cu_header: *const CuHeader,
};

const FormValue = union(enum) {
    uint: u64,
    int: i64,
    bool: bool,
    ref_offset: u64,
    index: u64,
    str: []const u8,
    block: []const u8,
};

const Attribute = struct {
    attr: u64,
    value: FormValue,
};

const Die = struct {
    abbrev_code: u64,
    tag: u64,
    attrs: []const Attribute,
    child_offset: u64,
    children: ?[]const Die,
};

const DwarfError = error{
    Unknown,
    Unsupported,
};

fn readDie(
    self: *DwarfInfo,
    context: *ParseContext,
    abbrevs: *const std.AutoHashMap(u64, Abbrev),
    data: []const u8,
    offset: *usize,
    parse_children: bool,
) (DwarfError || std.mem.Allocator.Error)!?Die {
    const abbrev_code = readUleb128(data, offset);
    if (abbrev_code == 0) {
        return null;
    }
    const abbrev = abbrevs.get(abbrev_code) orelse return DwarfError.Unknown;
    const SectionId = std.debug.Dwarf.Section.Id;

    // attributes
    for (abbrev.attributes) |abbrev_attr| {
        const FORM = std.dwarf.FORM;
        const value: FormValue = switch (abbrev_attr.form) {
            FORM.data1 => .{ .uint = readBytes(1, data, offset) },
            FORM.data2 => .{ .uint = readBytes(2, data, offset) },
            FORM.data4 => .{ .uint = readBytes(4, data, offset) },
            FORM.data8 => .{ .uint = readBytes(8, data, offset) },
            FORM.data16 => .{ .uint = readBytes(16, data, offset) },
            FORM.sdata => .{ .int = readSleb128(data, offset) },
            FORM.udata => .{ .uint = readUleb128(data, offset) },
            FORM.flag, FORM.flag_present => .{ .bool = readBytes(1, data, offset) != 0 },
            FORM.addr => .{ .ref_offset = readBytes(context.cu_header.addr_size, data, offset) },
            FORM.strp => .{ .str = readStrp(data, offset, &self.elf.dwarf.?, SectionId.debug_str) },
            FORM.line_strp => .{ .str = readStrp(data, offset, &self.elf.dwarf.?, SectionId.debug_line_str) },
            FORM.ref_addr, FORM.sec_offset => .{ .ref_offset = @intCast(readBytes(context.cu_header.dwarf_format, data, offset)) },
            FORM.rnglistx => .{ .index = readUleb128(data, offset) },
            FORM.block1 => .{ .block = readBlock(1, data, offset) },
            FORM.block2 => .{ .block = readBlock(2, data, offset) },
            FORM.block4 => .{ .block = readBlock(4, data, offset) },
            FORM.block, FORM.exprloc => .{ .block = readBlock(readUleb128(data, offset), data, offset) },
            else => return DwarfError.Unsupported,
        };
        const c: u64 = context.attr_scratch.items.len;
        _ = c;
        var attr = try context.attr_scratch.addOneBounded();
        attr.attr = abbrev_attr.attr;
        attr.value = value;
    }
    var die_attrs: []const Attribute = &.{};
    if (context.attr_scratch.items.len > 0) {
        die_attrs = try self.arena.allocator().dupe(Attribute, context.attr_scratch.items);
    }
    context.attr_scratch.clearRetainingCapacity();

    // children
    const child_offset = offset.*;
    var children: ?[]const Die = null;
    if (!abbrev.has_children) {
        children = &.{};
    } else if (parse_children and abbrev.has_children) {
        children = try self.readDieChildren(context, abbrevs, data, child_offset);
    }

    return .{ .abbrev_code = abbrev_code, .tag = abbrev.tag, .attrs = die_attrs, .child_offset = child_offset, .children = children };
}

fn readDieChildren(
    self: *DwarfInfo,
    context: *ParseContext,
    abbrevs: *const std.AutoHashMap(u64, Abbrev),
    data: []const u8,
    child_offset: u64,
) ![]const Die {
    const child_mark = context.die_scratch.items.len;
    var offset = child_offset;
    while (try self.readDie(context, abbrevs, data, &offset, true)) |child| {
        try context.die_scratch.append(self.gpa, child);
    }
    const child_count = context.die_scratch.items.len - child_mark;
    std.debug.assert(child_count > 0);
    const children = try self.arena.allocator().alloc(Die, child_count);
    context.die_scratch.shrinkRetainingCapacity(child_mark);

    return children;
}

const Cu = struct {
    header: CuHeader,
    die: Die,
};

fn readCu(self: *DwarfInfo, abbrevs: *const std.AutoHashMap(u64, Abbrev), data: []const u8, offset: *usize)!Cu {
    const header = readCuHeader(data, offset);
    var context: ParseContext = .{
        .attr_scratch = try .initCapacity(self.gpa, 64),
        .die_scratch = .empty,
        .cu_header = &header,
    };
    defer context.attr_scratch.deinit(self.gpa);
    defer context.die_scratch.deinit(self.gpa);
    const die = try self.readDie(&context, abbrevs, data, offset, false) orelse return DwarfError.Unknown;

    return .{ .header = header, .die = die };
}
