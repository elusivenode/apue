const std = @import("std");
const time = @import("time");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("hello from zig ({d})\n", .{time.utcTimestamp()});
}
