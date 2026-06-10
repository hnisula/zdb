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
    
    // check
    const check = b.step("check", "Build everything for analysis");
    check.dependOn(&zdb.step);
    check.dependOn(&tests.step);
}