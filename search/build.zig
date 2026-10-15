const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const validate = b.addSystemCommand(&.{ "python3", "generate_operations.py", "--check" });
    const exe = b.addExecutable(.{
        .name = "search",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.step.dependOn(&validate.step);
    exe.linkSystemLibrary("curl");
    exe.linkSystemLibrary("nats");
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run search").dependOn(&run.step);
    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.linkLibC();
    tests.step.dependOn(&validate.step);
    tests.linkSystemLibrary("curl");
    tests.linkSystemLibrary("nats");
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
