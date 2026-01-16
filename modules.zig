const std = @import("std");

pub const Modules = struct {
    c_include: std.Build.LazyPath,
    c_lib: *std.Build.Step.Compile,
    zig_time: *std.Build.Module,
};

pub fn make(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
    const c_lib = b.addStaticLibrary(.{
        .name = "csapp_c",
        .target = target,
        .optimize = optimize,
    });
    c_lib.addCSourceFile(.{ .file = b.path("lib/time.c"), .flags = &[_][]const u8{} });
    c_lib.addCSourceFile(.{ .file = b.path("lib/error.c"), .flags = &[_][]const u8{} });
    c_lib.linkLibC();

    const zig_time = b.addModule("time", .{
        .root_source_file = b.path("module/time.zig"),
    });

    return Modules{
        .c_include = b.path("lib"),
        .c_lib = c_lib,
        .zig_time = zig_time,
    };
}
