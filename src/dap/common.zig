const requests = @import("requests.zig");

pub const MessageType = enum {
    request,
    // response,
    // event,
    // custom,
};

pub const Message = union(MessageType) {
    request: requests.Request,
};