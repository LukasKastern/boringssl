const std = @import("std");

const TargetCommitSHA = "797ba56186260ef66d186deb200bd324ec1516c8";

const BoringSSLModule = struct {
    srcs: [][]const u8,
    hdrs: ?[][]const u8 = null,
    internal_hdrs: ?[][]const u8 = null,
    @"asm": ?[][]const u8 = null,
    nasm: ?[][]const u8 = null,
};

// These are all the sources that boring ssl exports in it's json
// Other dependencies here might be added as needed
const BuildSource = struct {
    bcm: BoringSSLModule,
    bssl: BoringSSLModule,
    crypto: BoringSSLModule,
    crypto_test: BoringSSLModule,
    // decrepit: BoringSSLModule,
    // decrepit_test: BoringSSLModule,
    // fuzz: BoringSSLModule,
    // modulewrapper: BoringSSLModule,
    // pki: BoringSSLModule,
    // pki_test: BoringSSLModule,
    // rust_bssl_crypto: BoringSSLModule,
    // rust_bssl_sys: BoringSSLModule,
    ssl: BoringSSLModule,
    ssl_test: BoringSSLModule,
    test_support: BoringSSLModule,
    // urandom_test: BoringSSLModule,
};

fn getNasmFormat(target: std.Target) []const u8 {
    switch (target.os.tag) {
        .windows => switch (target.cpu.arch) {
            .x86_64 => return "win64",
            .x86 => return "win32",
            else => return "bin",
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => return "elf64",
            .x86 => return "elf32",
            else => return "bin",
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => return "macho64",
            .x86 => return "macho",
            else => return "bin",
        },
        else => return "bin",
    }
}

fn addSourceFilesFromModule(b: *std.Build, step: *std.Build.Step.Compile, module: *const BoringSSLModule) !void {
    var srcs_c = try std.ArrayList([]const u8).initCapacity(b.allocator, module.srcs.len);
    var srcs_cpp = try std.ArrayList([]const u8).initCapacity(b.allocator, module.srcs.len);

    for (module.srcs) |src| {
        if (std.mem.endsWith(u8, src, ".c")) {
            srcs_c.appendAssumeCapacity(src);
        } else {
            srcs_cpp.appendAssumeCapacity(src);
        }
    }

    for (srcs_cpp.items) |item| {
        step.addCSourceFile(.{
            .file = b.path(b.pathJoin(&.{ "boringssl", item })),
            .flags = &.{ "-DWIN32_LEAN_AND_MEAN", "-std=c++17", "-DNOMINMAX" },
        });
    }

    for (srcs_c.items) |item| {
        step.addCSourceFile(.{
            .file = b.path(b.pathJoin(&.{ "boringssl", item })),
            .flags = &.{ "-DWIN32_LEAN_AND_MEAN", "-DNOMINMAX" },
        });
    }

    // Add asm
    if (module.@"asm") |asms| {
        for (asms) |@"asm"| {
            step.addCSourceFile(.{
                .file = b.path(b.pathJoin(&.{ "boringssl", @"asm" })),
                .flags = &.{""},
            });
        }
    }

    // Add nasm
    if (step.rootModuleTarget().os.tag == .windows) {
        if (module.nasm) |nasms| {
            const root = b.path("");

            for (nasms) |file| {
                std.debug.assert(!std.fs.path.isAbsolute(file));
                const src_file = b.path(b.pathJoin(&.{ "boringssl", file }));
                const file_stem = std.mem.sliceTo(file, '.');

                const nasm = b.addSystemCommand(&.{"nasm"});

                // Add platform
                const platform_arg = try std.fmt.allocPrint(b.allocator, "-f {s}", .{getNasmFormat(step.rootModuleTarget())});
                nasm.addArg(platform_arg);

                nasm.addPrefixedDirectoryArg("-i", root);
                const obj = nasm.addPrefixedOutputFileArg("-o", b.fmt("{s}.obj", .{file_stem}));
                nasm.addFileArg(src_file);

                step.addObjectFile(obj);
            }
        }
    }

    step.addIncludePath(b.path(b.pathJoin(&.{ "boringssl", "include" })));
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Clone source code
    // Ideally we would just reference boringssl in the zig.zon
    // But we need to apply patches which doesn't work nicely with the concept of cached dependecies
    cloneBoringSSL(b) catch |e| {
        std.log.err("failed to clone boringssl source code: {s}", .{@errorName(e)});
        return error.FailedToCloneBoringSSL;
    };

    // Grab the sources.json which tells us what to build
    const sources_json = b.path("boringssl/gen/sources.json");
    const sources_path = sources_json.getPath(b);

    const sources_file = try std.fs.cwd().openFile(sources_path, .{});
    const source_content = try sources_file.readToEndAlloc(b.allocator, 1024 * 1024 * 1024);

    // Parse it
    const source = try std.json.parseFromSlice(BuildSource, b.allocator, source_content, .{ .ignore_unknown_fields = true });

    // Extract
    const build_source = source.value;

    // Grab gtest from dependencies - we could use the one that comes with boringssl
    // But it's preferable to use the one that already floats around in the ecosystem to avoid symbol conflicts
    const gtest_dep = b.dependency("googletest", .{ .optimize = optimize, .target = target });
    const gtest = gtest_dep.artifact("gtest");
    const gmock = gtest_dep.artifact("gmock");

    const ModuleInfo = struct {
        name: []const u8,
        module: *const BoringSSLModule,
        kind: std.Build.Step.Compile.Kind,
        module_dependencies: ?[]const []const u8 = null,
        dependencies: []const *std.Build.Step.Compile = &.{},
        system_dependencies: []const []const u8 = &.{},
    };

    // Declare modules we want to build - these reference the sources we get from the json
    const modules: []const ModuleInfo = &.{
        ModuleInfo{
            .name = "bcm",
            .module = &build_source.bcm,
            .kind = .lib,
        },
        ModuleInfo{
            .name = "bssl",
            .module = &build_source.bssl,
            .kind = .exe,
            .module_dependencies = &.{
                "ssl",
                "crypto",
                "bcm",
            },
            .system_dependencies = if (target.result.os.tag == .windows) &.{ "Ws2_32", "DbgHelp" } else &.{},
        },
        ModuleInfo{
            .name = "crypto",
            .module = &build_source.crypto,
            .kind = .lib,
        },
        ModuleInfo{
            .name = "ssl",
            .module = &build_source.ssl,
            .kind = .lib,
        },
        ModuleInfo{
            .name = "test_support",
            .module = &build_source.test_support,
            .kind = .lib,
            .dependencies = &.{ gtest, gmock },
        },
        ModuleInfo{
            .name = "crypto_test",
            .module = &build_source.crypto_test,
            .kind = .lib,
            .dependencies = &.{ gtest, gmock },
        },
        ModuleInfo{
            .name = "ssl_test",
            .module = &build_source.ssl_test,
            .kind = .exe,
            .module_dependencies = &.{
                "ssl",
                "crypto",
                "bcm",
                "test_support",
            },
            .dependencies = &.{ gtest, gmock },
            .system_dependencies = if (target.result.os.tag == .windows) &.{ "Ws2_32", "DbgHelp" } else &.{},
        },
    };

    // Keep track of added modules so others can depend on them
    var steps = std.StringArrayHashMap(*std.Build.Step.Compile).init(b.allocator);

    // Setup all modules to not require any order when modules depend on other modules
    for (modules) |*module| {
        const mod = blk: {
            switch (module.kind) {
                .exe => {
                    const mod = b.addExecutable(.{
                        .name = module.name,
                        .optimize = optimize,
                        .target = target,
                    });
                    break :blk mod;
                },
                .lib => {
                    const mod = b.addStaticLibrary(.{
                        .name = module.name,
                        .optimize = optimize,
                        .target = target,
                    });
                    break :blk mod;
                },
                else => {
                    unreachable;
                },
            }
        };

        // Add to set
        try steps.put(module.name, mod);
    }

    for (modules) |*module| {
        // This has to be valid - we just created it
        const mod = steps.get(module.name).?;

        // Link std
        mod.linkLibC();
        mod.linkLibCpp();

        // Add the sources from the json module to the zig mod
        try addSourceFilesFromModule(b, mod, module.module);

        // Link to other boringssl modules
        if (module.module_dependencies) |dependencies| {
            for (dependencies) |dep| {
                const step = steps.get(dep);
                if (step == null) {
                    std.log.err("Module: {s} depends on {s} but wasn't found - change the step order", .{ mod.name, dep });
                    return error.InvalidStepOrder;
                }

                mod.linkLibrary(step.?);
            }
        }

        // Link other libraries needed
        for (module.dependencies) |dep| {
            mod.linkLibrary(dep);
        }

        // Link system dependencies
        for (module.system_dependencies) |dep| {
            mod.linkSystemLibrary(dep);
        }

        b.installArtifact(mod);

        // Add to steps to allow others to reference us
        try steps.put(module.name, mod);
    }
}

fn cloneBoringSSL(b: *std.Build) !void {
    // Check if source is cloned
    // We check if the zig-clone-status file matches our target SHA
    // If it doesn't match we do a fresh clone - otherwise we are good
    const is_cloned = blk: {
        const clone_status_file = std.fs.cwd().openFile("boringssl/zig-clone-status", .{}) catch break :blk false;
        defer clone_status_file.close();

        const status = clone_status_file.readToEndAlloc(b.allocator, 4096) catch break :blk false;
        break :blk std.mem.eql(u8, status, TargetCommitSHA);
    };

    if (is_cloned) {
        return;
    }

    // Delete previous tree
    std.fs.cwd().deleteTree("boringssl") catch |e| {
        std.log.err("failed to delete tree: {s}", .{@errorName(e)});
        return error.FailedToDeleteBoringSSLDir;
    };

    std.fs.cwd().makeDir("boringssl") catch |e| {
        std.log.err("failed to create boringssl dir: {s}", .{@errorName(e)});
        return error.FailedToCreateBoringSSLDir;
    };

    // Open the just created directory
    var boringssl_dir = try std.fs.cwd().openDir("boringssl", .{});
    defer boringssl_dir.close();

    // We only want to clone the target commit - so we initialize the repo first
    _ = run(b, &.{ "git", "init" }, boringssl_dir);
    _ = run(b, &.{ "git", "remote", "add", "origin", "https://github.com/google/boringssl.git" }, boringssl_dir);
    _ = run(b, &.{ "git", "fetch", "--depth", "1", "origin", TargetCommitSHA }, boringssl_dir);
    _ = run(b, &.{ "git", "checkout", "FETCH_HEAD" }, boringssl_dir);

    // Apply patches
    const patch_dir = try std.fs.cwd().openDir("patches", .{ .iterate = true });
    var iterator = patch_dir.iterate();
    while (try iterator.next()) |patch| {
        const abs_patch_patch = try b.build_root.handle.realpathAlloc(b.allocator, try std.fmt.allocPrint(b.allocator, "patches/{s}", .{patch.name}));
        _ = run(b, &.{ "git", "apply", abs_patch_patch }, boringssl_dir);
    }

    const done = try boringssl_dir.createFile("zig-clone-status", .{});
    defer done.close();
    try done.writeAll(TargetCommitSHA);
}

fn runAllowFail(
    b: *std.Build,
    argv: []const []const u8,
    out_code: *u8,
    stderr_behavior: std.process.Child.StdIo,
    cwd: ?std.fs.Dir,
) std.Build.RunError![]u8 {
    std.debug.assert(argv.len != 0);

    if (!std.process.can_spawn)
        return error.ExecNotSupported;

    var path_name_buffer: [std.fs.max_path_bytes]u8 = undefined;

    const max_output_size = 400 * 1024;
    var child = std.process.Child.init(argv, b.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = stderr_behavior;
    child.env_map = &b.graph.env_map;

    if (cwd) |dir| {
        child.cwd = dir.realpath("", &path_name_buffer) catch return error.OutOfMemory;
    }

    try std.Build.Step.handleVerbose2(b, null, child.env_map, argv);
    try child.spawn();

    const stdout = child.stdout.?.reader().readAllAlloc(b.allocator, max_output_size) catch {
        return error.ReadFailure;
    };
    errdefer b.allocator.free(stdout);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                out_code.* = @as(u8, @truncate(code));
                return error.ExitCodeFailure;
            }
            return stdout;
        },
        .Signal, .Stopped, .Unknown => |code| {
            out_code.* = @as(u8, @truncate(code));
            return error.ProcessTerminated;
        },
    }
}

fn allocPrintCmd(ally: std.mem.Allocator, opt_cwd: ?[]const u8, argv: []const []const u8) error{OutOfMemory}![]u8 {
    var buf = std.ArrayList(u8).init(ally);
    if (opt_cwd) |cwd| try buf.writer().print("cd {s} && ", .{cwd});
    for (argv) |arg| {
        try buf.writer().print("{s} ", .{arg});
    }
    return buf.toOwnedSlice();
}

// This is a copy of the build's run function with cwd support
fn run(b: *std.Build, argv: []const []const u8, cwd: ?std.fs.Dir) []u8 {
    if (!std.process.can_spawn) {
        std.debug.print("unable to spawn the following command: cannot spawn child process\n{s}\n", .{
            try allocPrintCmd(b.allocator, null, argv),
        });
        std.process.exit(1);
    }

    var code: u8 = undefined;
    return runAllowFail(b, argv, &code, .Inherit, cwd) catch |err| {
        const printed_cmd = allocPrintCmd(b.allocator, null, argv) catch @panic("OOM");
        std.debug.print("unable to spawn the following command: {s}\n{s}\n", .{
            @errorName(err), printed_cmd,
        });
        std.process.exit(1);
    };
}
