const std = @import("std");

pub fn main() !void {
    var buf: [4096]u8 = undefined;

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    while (true) {
        const n = stdin.read(&buf) catch |err| {
            stderr.print("read error: {s}\n", .{@errorName(err)}) catch {};
            return err;
        };
        if (n == 0) break;
        stdout.writeAll(buf[0..n]) catch |err| {
            stderr.print("write error: {s}\n", .{@errorName(err)}) catch {};
            return err;
        };
    }
}
