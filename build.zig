const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // main
    const main_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    const zdb = b.addExecutable(.{ .name = "zdb", .root_module = main_module });
    b.installArtifact(zdb);

    // test
    const tests = b.addTest(.{ .name = "test", .root_module = main_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // test tasks?
    const test_artifact = b.addInstallArtifact(tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } });
    const install_test_step = b.step("install_test", "Create test binaries for debugging");
    install_test_step.dependOn(&test_artifact.step);

    // samples
    const sample1_module = b.createModule(.{
        .root_source_file = b.path("src/dap/samples/sample1.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sample1 = b.addExecutable(.{
        .name = "sample1",
        .root_module = sample1_module,
    });
    b.installArtifact(sample1);

    // run-test
    const run_test_module = b.createModule(.{
        .root_source_file = b.path("src/run_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_test = b.addExecutable(.{
        .name = "run-test",
        .root_module = run_test_module,
    });
    const run_test_cmd = b.addRunArtifact(run_test);
    b.installArtifact(run_test);
    const run_test_step = b.step("run-test", "Run run-test");
    run_test_step.dependOn(&run_test_cmd.step);

    // check (separate modules so they don't collide with the emitting compiles)
    const check_main = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    const check_sample1 = b.createModule(.{ .root_source_file = b.path("src/dap/samples/sample1.zig"), .target = target, .optimize = optimize });
    const check_run_test = b.createModule(.{ .root_source_file = b.path("src/run_test.zig"), .target = target, .optimize = optimize });

    const check = b.step("check", "Analyze everything (no emit)");
    check.dependOn(&b.addExecutable(.{ .name = "check-zdb", .root_module = check_main }).step);
    check.dependOn(&b.addTest(.{ .name = "check-test", .root_module = check_main }).step);
    check.dependOn(&b.addExecutable(.{ .name = "check-sample1", .root_module = check_sample1 }).step);
    check.dependOn(&b.addExecutable(.{ .name = "check-run-test", .root_module = check_run_test }).step);
}
