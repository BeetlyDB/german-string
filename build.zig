const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("german_string", .{
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "german_string",
        .root_module = mod,
        .use_llvm = true,
    });

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = mod,
        .use_llvm = true,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
