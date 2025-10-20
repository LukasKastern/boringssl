const std = @import("std");
const native_os = builtin.os.tag;
const builtin = @import("builtin");
const patch = @import("patch");

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

fn addSourceFilesFromModule(b: *std.Build, upsteam: std.Build.LazyPath, step: *std.Build.Step.Compile, module: *const BoringSSLModule, nasm: *std.Build.Step.Compile) !void {
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
            .file = upsteam.path(b, b.pathJoin(&.{item})),
            .flags = &.{ "-DWIN32_LEAN_AND_MEAN", "-std=c++17", "-DNOMINMAX" },
        });
    }

    for (srcs_c.items) |item| {
        step.addCSourceFile(.{
            .file = upsteam.path(b, b.pathJoin(&.{item})),
            .flags = &.{ "-DWIN32_LEAN_AND_MEAN", "-DNOMINMAX" },
        });
    }

    // Add asm
    if (module.@"asm") |asms| {
        for (asms) |@"asm"| {
            step.addCSourceFile(.{
                .file = upsteam.path(b, b.pathJoin(&.{@"asm"})),
                .flags = &.{""},
            });
        }
    }

    // Add nasm
    if (step.rootModuleTarget().os.tag == .windows) {
        if (module.nasm) |nasms| {
            const root = upsteam.path(b, "");

            for (nasms) |file| {
                std.debug.assert(!std.fs.path.isAbsolute(file));
                const src_file = upsteam.path(b, file);
                const file_stem = std.mem.sliceTo(file, '.');

                const nasm_run = b.addRunArtifact(nasm);

                // Add platform
                const platform_arg = try std.fmt.allocPrint(b.allocator, "-f {s}", .{getNasmFormat(step.rootModuleTarget())});
                nasm_run.addArg(platform_arg);

                nasm_run.addPrefixedDirectoryArg("-i", root);
                const obj = nasm_run.addPrefixedOutputFileArg("-o", b.fmt("{s}.obj", .{file_stem}));
                nasm_run.addFileArg(src_file);

                step.addObjectFile(obj);
            }
        }
    }

    step.addIncludePath(upsteam.path(b, b.pathJoin(&.{"include"})));
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_root = b.build_root.handle;

    const upsteam = b.dependency("boringssl", .{});

    const patch_step = patch.PatchStep.create(b, .{
        .optimize = .ReleaseSafe,
        .target = .{
            .query = .{},
            .result = builtin.target,
        },
        .root_directory = upsteam.path(""),
        .strip = 1,
    });

    // Add patches
    const patch_dir = try build_root.openDir("patches", .{ .iterate = true });
    var iterator = patch_dir.iterate();
    while (try iterator.next()) |p| {
        const patch_path = try std.fmt.allocPrint(b.allocator, "patches/{s}", .{p.name});
        patch_step.addPatch(b.path(patch_path));
    }

    const upstream_root = patch_step.getDirectory();

    // Grab the sources.json which tells us what to build
    const sources_file = try build_root.openFile("sources.json", .{});
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
            .system_dependencies = if (target.result.os.tag == .windows) &.{ "ws2_32", "dbghelp" } else &.{},
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
            .system_dependencies = if (target.result.os.tag == .windows) &.{ "ws2_32", "dbghelp" } else &.{},
        },
    };

    // Grab nasm
    const nasm_dep = b.dependency("nasm", .{
        .target = std.Build.ResolvedTarget{
            .query = .{},
            .result = builtin.target,
        },
        .optimize = .ReleaseSafe,
    });
    const nasm = nasm_dep.artifact("nasm");

    // Keep track of added modules so others can depend on them
    var steps = std.StringArrayHashMap(*std.Build.Step.Compile).init(b.allocator);

    // Setup all modules to not require any order when modules depend on other modules
    for (modules) |*module| {
        const mod = blk: {
            switch (module.kind) {
                .exe => {
                    const mod = b.addExecutable(.{
                        .name = module.name,
                        .root_module = b.createModule(.{
                            .target = target,
                            .optimize = optimize,
                        }),
                    });
                    break :blk mod;
                },
                .lib => {
                    const mod = b.addLibrary(.{
                        .name = module.name,
                        .root_module = b.createModule(.{
                            .target = target,
                            .optimize = optimize,
                        }),
                        .linkage = .static,
                    });
                    break :blk mod;
                },
                else => {
                    unreachable;
                },
            }
        };

        // Depend on patch
        mod.step.dependOn(&patch_step.step);

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
        try addSourceFilesFromModule(b, upstream_root, mod, module.module, nasm);

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
    }

    // Install headers directory - should only ssl do this or crypto as well?
    steps.get("ssl").?.installHeadersDirectory(upstream_root.path(b, "include"), "", .{});
}
