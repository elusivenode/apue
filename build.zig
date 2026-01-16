const std = @import("std");
const modules = @import("modules.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app = b.addExecutable(.{
        .name = "apue",
        .root_source_file = b.path("src/app/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(app);

    const run_cmd = b.addRunArtifact(app);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the TUI");
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");

    const shared = modules.make(b, target, optimize);

    addExamples(b, target, optimize, test_step, shared) catch |err| {
        std.debug.panic("failed to scan examples: {s}", .{@errorName(err)});
    };
}

fn addExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    shared: modules.Modules,
) !void {
    const allocator = b.allocator;

    var dir = try std.fs.cwd().openDir("examples", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const ext = std.fs.path.extension(entry.path);
        if (!std.mem.eql(u8, ext, ".c") and !std.mem.eql(u8, ext, ".zig")) continue;

        const base = std.fs.path.basename(entry.path);
        const rel_path = try std.fs.path.join(allocator, &[_][]const u8{ "examples", entry.path });
        defer allocator.free(rel_path);
        const source_path = b.path(rel_path);

        if (std.mem.eql(u8, ext, ".zig") and std.mem.endsWith(u8, base, "_test.zig")) {
            const test_exe = b.addTest(.{
                .root_source_file = source_path,
                .target = target,
                .optimize = optimize,
            });
            const run_test = b.addRunArtifact(test_exe);
            test_step.dependOn(&run_test.step);
            continue;
        }

        const stem = std.fs.path.stem(base);
        if (std.mem.eql(u8, ext, ".c")) {
            const exe = b.addExecutable(.{
                .name = stem,
                .target = target,
                .optimize = optimize,
            });
            exe.addCSourceFile(.{ .file = source_path, .flags = &[_][]const u8{} });
            exe.addIncludePath(shared.c_include);
            exe.linkLibrary(shared.c_lib);
            exe.linkLibC();
            b.installArtifact(exe);
        } else if (std.mem.eql(u8, ext, ".zig")) {
            const exe = b.addExecutable(.{
                .name = stem,
                .root_source_file = source_path,
                .target = target,
                .optimize = optimize,
            });
            exe.root_module.addImport("time", shared.zig_time);
            b.installArtifact(exe);
        }
    }
}
