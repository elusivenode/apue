const std = @import("std");

const App = struct {
    allocator: std.mem.Allocator,
    examples: []Example,

    const Example = struct {
        display: []const u8,
        exe_name: []const u8,
    };

    fn init(allocator: std.mem.Allocator) !App {
        var list = std.ArrayList(Example).init(allocator);
        errdefer list.deinit();

        var dir = try std.fs.cwd().openDir("examples", .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            const ext = std.fs.path.extension(entry.path);
            if (!std.mem.eql(u8, ext, ".c") and !std.mem.eql(u8, ext, ".zig")) continue;

            const base = std.fs.path.basename(entry.path);
            if (std.mem.eql(u8, ext, ".zig") and std.mem.endsWith(u8, base, "_test.zig")) continue;

            const stem = std.fs.path.stem(base);
            const display = try allocator.dupe(u8, entry.path[0 .. entry.path.len - ext.len]);
            errdefer allocator.free(display);
            const exe_name = try allocator.dupe(u8, stem);
            errdefer allocator.free(exe_name);

            try list.append(.{ .display = display, .exe_name = exe_name });
        }

        std.sort.block(Example, list.items, {}, struct {
            fn lessThan(_: void, lhs: Example, rhs: Example) bool {
                return std.mem.lessThan(u8, lhs.display, rhs.display);
            }
        }.lessThan);

        return App{ .allocator = allocator, .examples = try list.toOwnedSlice() };
    }

    fn deinit(self: *App) void {
        for (self.examples) |example| {
            self.allocator.free(example.display);
            self.allocator.free(example.exe_name);
        }
        self.allocator.free(self.examples);
    }
};

fn clearScreen(writer: anytype) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
}

fn runExample(allocator: std.mem.Allocator, example: App.Example, args: []const []const u8) ![]u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);

    const exe_path = try std.fs.path.join(allocator, &[_][]const u8{ exe_dir, example.exe_name });
    defer allocator.free(exe_path);

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(exe_path);
    try argv.appendSlice(args);

    var proc = std.process.Child.init(argv.items, allocator);
    proc.stdin_behavior = .Ignore;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;

    try proc.spawn();
    var stdout_buf = std.ArrayListUnmanaged(u8){};
    var stderr_buf = std.ArrayListUnmanaged(u8){};
    errdefer stdout_buf.deinit(allocator);
    errdefer stderr_buf.deinit(allocator);
    try proc.collectOutput(allocator, &stdout_buf, &stderr_buf, 64 * 1024);
    _ = try proc.wait();

    const stdout_slice = try stdout_buf.toOwnedSlice(allocator);
    defer allocator.free(stdout_slice);
    const stderr_slice = try stderr_buf.toOwnedSlice(allocator);
    defer allocator.free(stderr_slice);

    var combined = std.ArrayList(u8).init(allocator);
    errdefer combined.deinit();
    try combined.appendSlice(stdout_slice);
    if (stderr_slice.len > 0) {
        if (stdout_slice.len > 0 and stdout_slice[stdout_slice.len - 1] != '\n') {
            try combined.append('\n');
        }
        try combined.appendSlice("--- stderr ---\n");
        try combined.appendSlice(stderr_slice);
    }

    return try combined.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    const stdin = std.io.getStdIn().reader();
    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    const out = stdout.writer();

    var selected: usize = 0;

    while (true) {
        try clearScreen(out);
        try out.writeAll("APUE examples\n\n");
        if (app.examples.len == 0) {
            try out.writeAll("No examples found under examples/\n\n");
        } else {
            for (app.examples, 0..) |example, idx| {
                const marker: []const u8 = if (idx == selected) "> " else "  ";
                try out.print("{s}[{d}] {s}\n", .{ marker, idx, example.display });
            }
        }

        try out.writeAll("\nEnter number (args ok), j/k to move, q to quit: ");
        try stdout.flush();

        var buf: [256]u8 = undefined;
        const n = try stdin.read(&buf);
        if (n == 0) break;

        const input = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (input.len == 0) continue;

        if (input.len == 1 and (input[0] == 'q' or input[0] == 'j' or input[0] == 'k')) {
            switch (input[0]) {
                'q' => break,
                'j' => {
                    if (app.examples.len > 0) selected = (selected + 1) % app.examples.len;
                },
                'k' => {
                    if (app.examples.len > 0) selected = (selected + app.examples.len - 1) % app.examples.len;
                },
                else => {},
            }
            continue;
        }

        var tokens = std.mem.tokenizeAny(u8, input, " \t");
        const first = tokens.next() orelse continue;
        const parsed = std.fmt.parseInt(usize, first, 10) catch null;
        if (parsed == null) continue;

        const idx = parsed.?;
        if (idx < app.examples.len) {
            selected = idx;
        } else {
            continue;
        }

        if (app.examples.len == 0) continue;

        var arg_list = std.ArrayList([]const u8).init(allocator);
        defer {
            for (arg_list.items) |arg| allocator.free(arg);
            arg_list.deinit();
        }
        while (tokens.next()) |arg| {
            const duped = try allocator.dupe(u8, arg);
            arg_list.append(duped) catch |err| {
                allocator.free(duped);
                return err;
            };
        }

        const output = try runExample(allocator, app.examples[selected], arg_list.items);
        defer allocator.free(output);

        try clearScreen(out);
        try out.print("{s}\n", .{output});
        try out.writeAll("\nPress Enter to continue...");
        try stdout.flush();
        _ = try stdin.read(&buf);
    }
}
