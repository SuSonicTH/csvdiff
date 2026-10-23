const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "csvdiff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // src/arguments.zig embeds LICENSE.txt with @embedFile, but the file lives
    // in the project root. Expose it as an anonymous import so the module can
    // see it.
    exe.root_module.addAnonymousImport("LICENSE.txt", .{
        .root_source_file = b.path("LICENSE.txt"),
    });

    if (optimize != .debug) {
        exe.root_module.strip = true;
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe_unit_tests.root_module.addAnonymousImport("LICENSE.txt", .{
        .root_source_file = b.path("LICENSE.txt"),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
