const std = @import("std");

const TargetConfig = struct {
    query: std.Target.Query,
    suffix: []const u8,
};

const release_targets = [_]TargetConfig{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux }, .suffix = "x86_64-linux" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux }, .suffix = "aarch64-linux" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .suffix = "x86_64-windows" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = compileStep(b, target, optimize, "csvdiff");
    b.installArtifact(exe);

    // release
    const release = b.step("release", "Build compressed release binaries for all supported platforms");
    releasebuild(b, release);

    // native
    const native = b.step("native", "Build an optimized, compressed release binary for the host");
    native.dependOn(nativebuild(b));

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

fn releasebuild(b: *std.Build, release: *std.Build.Step) void {
    const zupx = b.dependency("zupx", .{
        .optimize = std.builtin.OptimizeMode.fast,
        .target = b.graph.host,
    });

    for (release_targets) |config| {
        const target = b.resolveTargetQuery(config.query);
        const exe_name = b.fmt("csvdiff-{s}", .{config.suffix});
        const install_name = if (config.query.os_tag == .windows)
            b.fmt("{s}.exe", .{exe_name})
        else
            exe_name;
        const exe = compileStep(b, target, std.builtin.OptimizeMode.fast, exe_name);
        const install_artifact = upxInstall(b, zupx, exe, install_name);
        release.dependOn(&install_artifact.step);
    }
}

/// Compresses the compiled executable with upx, installing only the packed
/// output so that the cached artifact is never modified in place.
fn upxInstall(
    b: *std.Build,
    zupx: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
    exe_name: []const u8,
) *std.Build.Step.InstallFile {
    const upx_cmd = b.addRunArtifact(zupx.artifact("upx"));
    upx_cmd.addArg("--lzma");
    upx_cmd.addArg("-o");
    const packed_path = upx_cmd.addOutputFileArg(exe_name);
    upx_cmd.addFileArg(exe.getEmittedBin());
    return b.addInstallFileWithDir(packed_path, .bin, exe_name);
}

fn nativebuild(b: *std.Build) *std.Build.Step {
    const zupx = b.dependency("zupx", .{
        .optimize = std.builtin.OptimizeMode.fast,
        .target = b.graph.host,
    });

    const exe = compileStep(b, b.graph.host, std.builtin.OptimizeMode.fast, "csvdiff");
    const install_name = if (b.graph.host.result.os.tag == .windows) "csvdiff.exe" else "csvdiff";
    const install_artifact = upxInstall(b, zupx, exe, install_name);
    return &install_artifact.step;
}

fn compileStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = exe_name,
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

    return exe;
}
