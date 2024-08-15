const std = @import("std");
const duckdbext = @import("duckdbext.zig");
const proto = @import("proto/protos.pb.zig");
const protobuf = @import("protobuf");
const zstd = @import("std").compress.zstd;
const c = @cImport(@cInclude("duckdb.h"));
const bridge = @cImport(@cInclude("bridge.h"));
const Reconstructor = @import("spawnlog_reconstructor.zig").Reconstructor;

const InitData = struct { done: bool, gpa: std.heap.GeneralPurposeAllocator(.{}), file: std.fs.File, reader: Reconstructor(zstd.Decompressor(std.fs.File.Reader)) };

const BindData = struct {
    path: []u8,
};

export fn compact_execlog_version_zig() [*:0]const u8 {
    return duckdbext.duckdbVersion();
}

test compact_execlog_version_zig {
    try std.testing.expectEqualStrings(
        "v1.0.0",
        std.mem.sliceTo(compact_execlog_version_zig(), 0),
    );
}

/// called by c++ bridge when loading ext
export fn compact_execlog_init(db: *anyopaque) void {
    std.log.debug("initializing ext...", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conn = duckdbext.Connection.init(
        allocator,
        duckdbext.DB.provided(@ptrCast(@alignCast(db))),
    ) catch |e| {
        std.debug.print(
            "error connecting to duckdb {any}\n",
            .{e},
        );
        @panic("error connecting to duckdb");
    };
    defer conn.deinit();

    compact_execlog_init_zig(&conn);
}

// split for test injection
fn compact_execlog_init_zig(conn: *duckdbext.Connection) void {
    var table_func = duckdbext.TableFunction(
        InitData,
        BindData,
        init,
        bind,
        func,
    ){
        .name = "load_compact_execlog",
        .parameters = &[_]duckdbext.LogicalType{
            .varchar,
        },
    };

    if (!conn.registerTableFunction(table_func.create())) {
        std.debug.print("error registering duckdb table func\n", .{});
        return;
    }
}

test compact_execlog_init_zig {
    const allocator = std.testing.allocator;

    var db = try duckdbext.DB.memory(allocator);
    defer db.deinit();

    var conn = duckdbext.Connection.init(
        allocator,
        db,
    ) catch |e| {
        std.debug.print(
            "error connecting to duckdb {any}\n",
            .{e},
        );
        @panic("error connecting to duckdb");
    };
    defer conn.deinit();

    compact_execlog_init_zig(&conn);
    // todo exec test query
}

fn bind(info: *duckdbext.BindInfo, data: *BindData) !void {
    var varchar_list_type = c.duckdb_create_list_type(duckdbext.LogicalType.varchar.toInternal().ptr);
    defer c.duckdb_destroy_logical_type(&varchar_list_type);

    var envvars_type = c.duckdb_create_struct_type(
        @constCast(&[_]c.duckdb_logical_type{ duckdbext.LogicalType.varchar.toInternal().ptr, duckdbext.LogicalType.varchar.toInternal().ptr }),
        @constCast(@alignCast(@ptrCast(&[_][*c]u8{ @constCast("name"), @constCast("value") }))),
        2,
    );
    defer c.duckdb_destroy_logical_type(&envvars_type);

    var platform_property_type = c.duckdb_create_struct_type(
        @constCast(&[_]c.duckdb_logical_type{ duckdbext.LogicalType.varchar.toInternal().ptr, duckdbext.LogicalType.varchar.toInternal().ptr }),
        @constCast(@alignCast(@ptrCast(&[_][*c]u8{ @constCast("name"), @constCast("value") }))),
        2,
    );
    defer c.duckdb_destroy_logical_type(&platform_property_type);
    var platform_properties_type = c.duckdb_create_list_type(platform_property_type);
    defer c.duckdb_destroy_logical_type(&platform_properties_type);
    var platform_type = c.duckdb_create_struct_type(
        @constCast(&[_]c.duckdb_logical_type{platform_properties_type}),
        @constCast(@alignCast(@ptrCast(&[_][*c]u8{@constCast("properties")}))),
        1,
    );
    defer c.duckdb_destroy_logical_type(&platform_type);

    var digest_type = c.duckdb_create_struct_type(
        @constCast(&[_]c.duckdb_logical_type{ duckdbext.LogicalType.varchar.toInternal().ptr, duckdbext.LogicalType.int.toInternal().ptr, duckdbext.LogicalType.varchar.toInternal().ptr }),
        @constCast(@alignCast(@ptrCast(&[_][*c]u8{ @constCast("hash"), @constCast("size_bytes"), @constCast("hash_function_name") }))),
        3,
    );
    defer c.duckdb_destroy_logical_type(&digest_type);

    var file_type = c.duckdb_create_struct_type(
        @constCast(&[_]c.duckdb_logical_type{ duckdbext.LogicalType.varchar.toInternal().ptr, duckdbext.LogicalType.varchar.toInternal().ptr, digest_type, duckdbext.LogicalType.bool.toInternal().ptr }),
        @constCast(@alignCast(@ptrCast(&[_][*c]u8{ @constCast("path"), @constCast("symlink_target_path"), @constCast("digest"), @constCast("is_tool") }))),
        4,
    );
    defer c.duckdb_destroy_logical_type(&file_type);
    var files_type = c.duckdb_create_list_type(file_type);
    defer c.duckdb_destroy_logical_type(&files_type);

    var metrics_type = c.duckdb_create_struct_type(
        @constCast(&[_]c.duckdb_logical_type{
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.int.toInternal().ptr,
            duckdbext.LogicalType.int.toInternal().ptr,
            duckdbext.LogicalType.int.toInternal().ptr,
            duckdbext.LogicalType.int.toInternal().ptr,
            duckdbext.LogicalType.int.toInternal().ptr,
            duckdbext.LogicalType.int.toInternal().ptr,
            duckdbext.LogicalType.int.toInternal().ptr,
            duckdbext.LogicalType.int.toInternal().ptr,
            duckdbext.LogicalType.interval.toInternal().ptr,
            duckdbext.LogicalType.timestamp_ns.toInternal().ptr,
        }),
        @constCast(@alignCast(@ptrCast(&[_][*c]u8{
            @constCast("total_time"),
            @constCast("parse_time"),
            @constCast("network_time"),
            @constCast("fetch_time"),
            @constCast("queue_time"),
            @constCast("setup_time"),
            @constCast("upload_time"),
            @constCast("execution_wall_time"),
            @constCast("process_outputs_time"),
            @constCast("retry_time"),
            @constCast("input_bytes"),
            @constCast("input_files"),
            @constCast("memory_estimate_bytes"),
            @constCast("input_bytes_limit"),
            @constCast("input_files_limit"),
            @constCast("output_bytes_limit"),
            @constCast("output_files_limit"),
            @constCast("memory_bytes_limit"),
            @constCast("time_limit"),
            @constCast("start_time"),
        }))),
        20,
    );
    defer c.duckdb_destroy_logical_type(&metrics_type);

    // info.addResultColumn("quacks", .varchar);
    c.duckdb_bind_add_result_column(info.ptr, "command_args", varchar_list_type);
    c.duckdb_bind_add_result_column(info.ptr, "environment_variables", envvars_type);
    c.duckdb_bind_add_result_column(info.ptr, "platform", platform_type);
    c.duckdb_bind_add_result_column(info.ptr, "inputs", files_type);
    c.duckdb_bind_add_result_column(info.ptr, "lsted_outputs", varchar_list_type);
    c.duckdb_bind_add_result_column(info.ptr, "remotable", duckdbext.LogicalType.bool.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "cacheable", duckdbext.LogicalType.bool.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "timeout_millis", duckdbext.LogicalType.int.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "mnemonic", duckdbext.LogicalType.varchar.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "actual_outputs", files_type);
    c.duckdb_bind_add_result_column(info.ptr, "runner", duckdbext.LogicalType.varchar.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "cache_hit", duckdbext.LogicalType.bool.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "status", duckdbext.LogicalType.varchar.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "exit_code", duckdbext.LogicalType.int.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "remote_cacheable", duckdbext.LogicalType.bool.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "target_label", duckdbext.LogicalType.varchar.toInternal().ptr);
    c.duckdb_bind_add_result_column(info.ptr, "digest", digest_type);
    c.duckdb_bind_add_result_column(info.ptr, "metrics", metrics_type);

    var pathParam: duckdbext.Value = info.getParameter(0) orelse {
        info.setErr("path to execlog required");
        return;
    };
    defer pathParam.deinit();
    // defer c.duckdb_free(&path);

    data.path = std.mem.span(pathParam.toString());
}

fn init(info: *duckdbext.InitInfo, data: *InitData) !void {
    data.done = false;
    const bindData: *BindData = @ptrCast(@alignCast(c.duckdb_init_get_bind_data(info.ptr)));

    data.gpa = std.heap.GeneralPurposeAllocator(.{}){};
    data.file = try std.fs.cwd().openFile(bindData.path, .{});

    const zstdBuffer = try data.gpa.allocator().create([zstd.DecompressorOptions.default_window_buffer_len]u8);

    data.reader = Reconstructor(zstd.Decompressor(std.fs.File.Reader)).init(zstd.decompressor(data.file.reader(), .{ .window_buffer = zstdBuffer }), data.gpa.allocator());
}

const maxVarintLen = 10;

fn func(chunk: *duckdbext.DataChunk, initData: *InitData, _: *BindData) !void {
    if (initData.done) {
        chunk.setSize(0);
        initData.file.close();
        _ = initData.gpa.deinit();
        return;
    }

    bridge.duckdb_data_chunk_set_value(@ptrCast(chunk.ptr), 0, 0, null);

    // const vec_size = c.duckdb_vector_size();

    // var idx: u64 = 0;
    // while (idx < vec_size-1): (idx += 1) {
    //     const spawn = try initData.reader.getSpawnExec() orelse {
    //         initData.done = true;
    //         break;
    //     };
    //     std.debug.print("GOT EXEC {s} {s}\n", .{ spawn.target_label.getSlice(), spawn.mnemonic.getSlice() });
    // }
    // chunk.setSize(idx);

    initData.done = true;

    // const repeated = try repeat(allocator, "🐥", 3);
    // defer allocator.free(repeated);
    for (0..10) |i| {
        chunk.vector(0).assignStringElement(i, "🐥");
    }
    chunk.setSize(10);
}
