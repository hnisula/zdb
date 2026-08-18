const std = @import("std");

const Session = @import("../Session.zig");

test "breakpoint_loop" {
    const session: Session = .init("../samples/sample1", std.testing.io, std.testing.allocator);
    defer session.deinit();
}