const std = @import("std");

pub fn main() !void {
    const pid = std.c.getpid();

    const stdout = std.io.getStdOut().writer();

    try stdout.print("hello world from process ID {d}\n", .{pid});
}
