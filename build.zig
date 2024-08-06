const std = @import("std");
const duckdb = @import("duckdb.build.zig");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("duckdb_ext", .{
        .root_source_file = b.path("src/duckdbext.zig"),
    });

    const name = "compact_execlog";
    const lib = b.addSharedLibrary(.{
        .name = name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // duckdb headers
    const duckdb_third_party_path = try std.process.getEnvVarOwned(allocator, "DUCKDB_THIRD_PARTY_PATH");
    defer _ = allocator.free(duckdb_third_party_path);
    const duckdb_dev_path = try std.process.getEnvVarOwned(allocator, "DUCKDB_DEV_PATH");
    defer _ = allocator.free(duckdb_dev_path);

    const duckdb_include_path = try std.fmt.allocPrint(allocator, "{s}/include", .{duckdb_dev_path});
    defer _ = allocator.free(duckdb_include_path);
    lib.addIncludePath(.{ .cwd_relative = duckdb_include_path });
    const duckdb_re_path = try std.fmt.allocPrint(allocator, "{s}/re2", .{duckdb_third_party_path});
    defer _ = allocator.free(duckdb_re_path);
    lib.addIncludePath(.{ .cwd_relative = duckdb_re_path });

    // our c bridge
    lib.addIncludePath(b.path("src/include"));
    // our c++ bridge
    lib.addCSourceFile(.{ .file = b.path("src/bridge.cpp") });

    lib.linkLibC();
    // https://github.com/ziglang/zig/blob/e1ca6946bee3acf9cbdf6e5ea30fa2d55304365d/build.zig#L369-L373
    lib.linkSystemLibrary("c++");

    lib.linkSystemLibrary("duckdb");
    lib.addLibraryPath(b.path("lib"));

    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));

    const gen_proto = b.step("gen-proto", "generates zig files from protocol buffer definitions");

    const protoc_step = protobuf.RunProtocStep.create(b, protobuf_dep.builder, target, .{
        // out directory for the generated zig files
        .destination_directory = b.path("src/proto"),
        .source_files = &.{
            "proto/spawn.proto",
        },
        .include_directories = &.{},
    });

    gen_proto.dependOn(&protoc_step.step);

    b.getInstallStep().dependOn(&duckdb.appendMetadata(
        b,
        b.addInstallArtifact(
            lib,
            .{
                .dest_sub_path = name ++ ".duckdb_extension",
            },
        ),
        .{ .platform = "linux_amd64" },
    ).step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // duckdb headers
    main_tests.addIncludePath(b.path("duckdb/src/include"));
    main_tests.addIncludePath(b.path("duckdb/third_party/re2"));

    // our c bridge
    main_tests.addIncludePath(b.path("src/include"));

    // our c++ bridge
    main_tests.addCSourceFile(.{ .file = b.path("src/bridge.cpp") });

    main_tests.linkLibC();
    // https://github.com/ziglang/zig/blob/e1ca6946bee3acf9cbdf6e5ea30fa2d55304365d/build.zig#L369-L373
    main_tests.linkSystemLibrary("c++");

    main_tests.linkSystemLibrary("duckdb");
    main_tests.addLibraryPath(b.path("lib"));

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
