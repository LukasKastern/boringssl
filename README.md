# BoringSSL

This is [BoringSSL](https://github.com/google/boringssl), packaged for Zig.

## Installation

First, update your `build.zig.zon`:

```
# Initialize a `zig build` project if you haven't already
zig init
zig fetch --save git+https://github.com/lukaskastern/boringssl.git#0.20250514.0
```

You can then import `boringssl` in your `build.zig` with:

```zig
const boringssl_dependency = b.dependency("boringssl", .{
    .target = target,
    .optimize = optimize,
});
your_exe.linkLibrary(boringssl_dependency.artifact("ssl"));
your_exe.linkLibrary(boringssl_dependency.artifact("crypto"));
```

## System Dependencies

### Generic

- Git

### Windows

- Nasm

## Notes

### Windows support:
At the moment only x86_64-windows-gnu is functional. MSVC doesn't work!

GNU doesn't seem an official target by boringssl for windows which is why need the [patch](patches/p256_gnuc.patch).

### Zig Version
The target zig version is 0.14.0
