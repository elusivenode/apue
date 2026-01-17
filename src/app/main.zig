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

fn helpStem(exe_name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, exe_name, "_zig")) {
        return exe_name[0 .. exe_name.len - "_zig".len];
    }
    if (std.mem.endsWith(u8, exe_name, "_c")) {
        return exe_name[0 .. exe_name.len - "_c".len];
    }
    return exe_name;
}

fn showHelp(allocator: std.mem.Allocator, writer: anytype, example: App.Example) !void {
    const stem = helpStem(example.exe_name);
    const help_files = [_][]const u8{
        try std.fmt.allocPrint(allocator, "help_{s}.txt", .{stem}),
        try std.fmt.allocPrint(allocator, "help_ {s}.txt", .{stem}),
    };
    defer {
        allocator.free(help_files[0]);
        allocator.free(help_files[1]);
    }

    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
    defer if (exe_dir) |dir| allocator.free(dir);

    var file: ?std.fs.File = null;
    for (help_files) |help_file| {
        if (file == null) {
            if (exe_dir) |dir| {
                const from_exe = try std.fs.path.join(allocator, &[_][]const u8{
                    dir,
                    "..",
                    "..",
                    "docs",
                    "help",
                    help_file,
                });
                defer allocator.free(from_exe);
                file = std.fs.cwd().openFile(from_exe, .{}) catch null;
            }
        }
        if (file == null) {
            const from_cwd = try std.fs.path.join(allocator, &[_][]const u8{
                "docs",
                "help",
                help_file,
            });
            defer allocator.free(from_cwd);
            file = std.fs.cwd().openFile(from_cwd, .{}) catch null;
        }
    }

    if (file == null) {
        try writer.print("No help available for {s}\n", .{example.display});
        return;
    }

    defer file.?.close();
    const help = try file.?.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(help);

    try writer.writeAll(help);
    if (help.len == 0 or help[help.len - 1] != '\n') {
        try writer.writeAll("\n");
    }
}

fn findExampleIndex(app: App, name: []const u8) ?usize {
    for (app.examples, 0..) |example, idx| {
        if (std.mem.eql(u8, example.exe_name, name) or std.mem.eql(u8, example.display, name)) {
            return idx;
        }
    }
    return null;
}

fn runCommand(allocator: std.mem.Allocator, argv_items: []const []const u8, stdin_data: ?[]const u8) ![]u8 {
    var proc = std.process.Child.init(argv_items, allocator);
    proc.stdin_behavior = if (stdin_data == null) .Ignore else .Pipe;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;

    proc.spawn() catch |err| {
        var message = std.ArrayList(u8).init(allocator);
        errdefer message.deinit();
        try message.writer().print("error: {s}\n", .{@errorName(err)});
        return message.toOwnedSlice();
    };
    if (stdin_data) |data| {
        if (proc.stdin) |stdin_file| {
            try stdin_file.writeAll(data);
            stdin_file.close();
            proc.stdin = null;
        }
    }

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

fn runShellCommand(allocator: std.mem.Allocator, command: []const u8, stdin_data: ?[]const u8) ![]u8 {
    var argv = [_][]const u8{ "/bin/sh", "-c", command };
    return runCommand(allocator, &argv, stdin_data);
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

        var buf: [256]u8 = undefined;

        try out.writeAll("\nCommand (index/program/path + args, pipes ok, -h for help): \n");
        try stdout.flush();

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

        if (std.mem.indexOfAny(u8, input, "|<>") != null) {
            var tokens = std.mem.tokenizeAny(u8, input, " \t");
            const first = tokens.next() orelse continue;
            const parsed = std.fmt.parseInt(usize, first, 10) catch null;
            const resolved_idx = if (parsed) |value| blk: {
                if (value < app.examples.len) break :blk value;
                break :blk null;
            } else findExampleIndex(app, first);

            var cmd_owned: ?[]u8 = null;
            defer if (cmd_owned) |cmd| allocator.free(cmd);

            if (resolved_idx) |idx| {
                const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
                defer allocator.free(exe_dir);
                const exe_path = try std.fs.path.join(allocator, &[_][]const u8{
                    exe_dir,
                    app.examples[idx].exe_name,
                });
                defer allocator.free(exe_path);

                const rest = std.mem.trimLeft(u8, input[first.len..], " \t");
                if (rest.len == 0) {
                    cmd_owned = try allocator.dupe(u8, exe_path);
                } else {
                    cmd_owned = try std.fmt.allocPrint(allocator, "{s} {s}", .{ exe_path, rest });
                }
            }

            var stdin_data: ?[]u8 = null;
            defer if (stdin_data) |data| allocator.free(data);
            if (std.mem.indexOfAny(u8, input, "<|") == null) {
                try out.writeAll("\nstdin (optional, end with blank line):\n");
                try stdout.flush();
                var input_buf = std.ArrayList(u8).init(allocator);
                errdefer input_buf.deinit();
                while (true) {
                    const line = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
                    if (line == null) break;
                    defer allocator.free(line.?);
                    if (line.?.len == 0) break;
                    try input_buf.appendSlice(line.?);
                    try input_buf.append('\n');
                }
                if (input_buf.items.len > 0) {
                    stdin_data = try input_buf.toOwnedSlice();
                } else {
                    input_buf.deinit();
                }
            }

            const cmd = if (cmd_owned) |owned| owned else input;
            const output = try runShellCommand(allocator, cmd, stdin_data);
            defer allocator.free(output);

            try clearScreen(out);
            try out.print("{s}\n", .{output});
            try out.writeAll("\nPress Enter to continue...");
            try stdout.flush();
            _ = try stdin.read(&buf);
            continue;
        }

        var tokens = std.mem.tokenizeAny(u8, input, " \t");
        const first = tokens.next() orelse continue;
        const parsed = std.fmt.parseInt(usize, first, 10) catch null;

        var idx: usize = 0;
        var use_example = false;
        if (parsed) |value| {
            if (value < app.examples.len) {
                idx = value;
                selected = idx;
                use_example = true;
            } else {
                continue;
            }
        } else if (findExampleIndex(app, first)) |found| {
            idx = found;
            selected = idx;
            use_example = true;
        }

        if (app.examples.len == 0) continue;

        if (use_example) {
            var arg_list = std.ArrayList([]const u8).init(allocator);
            var show_help = false;
            defer {
                for (arg_list.items) |arg| allocator.free(arg);
                arg_list.deinit();
            }
            while (tokens.next()) |arg| {
                if (std.mem.eql(u8, arg, "-h")) {
                    show_help = true;
                }
                const duped = try allocator.dupe(u8, arg);
                arg_list.append(duped) catch |err| {
                    allocator.free(duped);
                    return err;
                };
            }

            try clearScreen(out);
            if (show_help) {
                try showHelp(allocator, out, app.examples[selected]);
            } else {
                const output = try runExample(allocator, app.examples[selected], arg_list.items);
                defer allocator.free(output);
                try out.print("{s}\n", .{output});
            }
        } else {
            var argv = std.ArrayList([]const u8).init(allocator);
            defer {
                for (argv.items) |arg| allocator.free(arg);
                argv.deinit();
            }
            const cmd_duped = try allocator.dupe(u8, first);
            argv.append(cmd_duped) catch |err| {
                allocator.free(cmd_duped);
                return err;
            };
            while (tokens.next()) |arg| {
                const duped = try allocator.dupe(u8, arg);
                argv.append(duped) catch |err| {
                    allocator.free(duped);
                    return err;
                };
            }

            const output = try runCommand(allocator, argv.items, null);
            defer allocator.free(output);

            try clearScreen(out);
            try out.print("{s}\n", .{output});
        }
        try out.writeAll("\nPress Enter to continue...");
        try stdout.flush();
        _ = try stdin.read(&buf);
    }
}
