const std = @import("std");
const duckdb = @import("duckdb.build.zig");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) !void {
    const gcc_suffix = b.option(bool, "gcc-suffix", "Whether to include _gcc4 suffix in the extension platform. Most Linux DuckDB CLI distributions require it") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const name = "compact_execlog";
    const lib = b.addSharedLibrary(.{
        .name = name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // duckdb headers
    const libduckdb_path = try std.process.getEnvVarOwned(b.allocator, "LIBDUCKDB_PATH");

    lib.linkLibC();
    lib.addIncludePath(.{
        .cwd_relative = try std.fmt.allocPrint(b.allocator, "{s}/include", .{libduckdb_path})
    });
    lib.addObjectFile(.{
        .cwd_relative = try std.fmt.allocPrint(b.allocator, "{s}/lib/libduckdb.a", .{libduckdb_path})
    });

    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));

    const gen_proto = b.step("gen-proto", "generates zig files from protocol buffer definitions");

    const protoc_step = protobuf.RunProtocStep.create(b, protobuf_dep.builder, target, .{
        .destination_directory = b.path("src/proto"),
        .source_files = &.{
            "proto/spawn.proto",
        },
        .include_directories = &.{},
    });

    gen_proto.dependOn(&protoc_step.step);

    const platform = try std.fmt.allocPrint(b.allocator, "{s}_{s}{s}", .{
        switch (target.result.os.tag) {
            .linux => "linux",
            .macos => "osx",
            else => @panic("only osx and darwin targets supported"),
        }, switch (target.result.cpu.arch) {
            .aarch64, .aarch64_be, .aarch64_32 => "arm64",
            .x86_64 => "amd64",
            else => @panic("only aarch64 and x86_64 supported")
        }, if (gcc_suffix) "_gcc4" else ""
    });

    b.getInstallStep().dependOn(&duckdb.appendMetadata(
        b,
        b.addInstallArtifact(
            lib,
            .{ .dest_sub_path = try std.fmt.allocPrint(b.allocator, "{s}.{s}.duckdb_extension", .{ name, platform }) },
        ),
        .{ .platform = platform },
    ).step);
}
