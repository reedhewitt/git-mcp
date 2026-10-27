const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "git-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run git-mcp").dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // End-to-end tests drive the built binary over stdio.
    const options = b.addOptions();
    options.addOptionPath("exe_path", exe.getEmittedBin());
    const testutil_mod = b.createModule(.{
        .root_source_file = b.path("src/testutil.zig"),
        .target = target,
        .optimize = optimize,
    });
    const e2e_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/e2e.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "testutil", .module = testutil_mod },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(e2e_tests).step);
}
