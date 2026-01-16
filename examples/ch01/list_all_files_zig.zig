const std = @import("std");

pub fn main() !void {
    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    const outw = stdout.writer();
    var stderr = std.io.bufferedWriter(std.io.getStdErr().writer());
    const errw = stderr.writer();
    const allocator = std.heap.page_allocator;

    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();

    _ = args_it.next();
    const fp = args_it.next() orelse return {
        try errw.print("usage: ls directory_name\n", .{});
        try stderr.flush();
        return error.InvalidArgs;
    };
    if (args_it.next() != null) {
        try errw.print("usage: ls directory_name\n", .{});
        try stderr.flush();
        return error.InvalidArgs;
    }

    var dir = std.fs.cwd().openDir(fp, .{ .iterate = true }) catch |open_err| {
        const msg = switch (open_err) {
            error.FileNotFound => "No such file or directory",
            error.NotDir => "Not a directory",
            error.AccessDenied => "Permission denied",
            else => @errorName(open_err),
        };
        try errw.print("can't open {s}: {s}\n", .{ fp, msg });
        try stderr.flush();
        return open_err;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        try outw.print(" - {s} ({s})\n", .{
            entry.name,
            @tagName(entry.kind), // File, Directory, Symlink, etc.
        });
    }
    try stdout.flush();
}
