// TODO: there are destructor functions for these that we should prolly call
const bridge = @cImport(@cInclude("duckdb.h"));
const duckdbext = @import("duckdbext.zig");

pub fn varchar_list_type() bridge.duckdb_logical_type {
    return bridge.duckdb_create_list_type(duckdbext.LogicalType.varchar.toInternal().ptr);
}

pub fn envvars_type() bridge.duckdb_logical_type {
    return bridge.duckdb_create_list_type(
        bridge.duckdb_create_struct_type(
            @constCast(&[_]bridge.duckdb_logical_type{ duckdbext.LogicalType.varchar.toInternal().ptr, duckdbext.LogicalType.varchar.toInternal().ptr }),
            @constCast(@alignCast(@ptrCast(&[_][*c]u8{ @constCast("name"), @constCast("value") }))),
            2,
        ),
    );
}

pub fn platform_properties_type() bridge.duckdb_logical_type {
    return bridge.duckdb_create_list_type(
        bridge.duckdb_create_struct_type(
            @constCast(&[_]bridge.duckdb_logical_type{ duckdbext.LogicalType.varchar.toInternal().ptr, duckdbext.LogicalType.varchar.toInternal().ptr }),
            @constCast(@alignCast(@ptrCast(&[_][*c]u8{ @constCast("name"), @constCast("value") }))),
            2,
        ),
    );
}

pub fn digest_type() bridge.duckdb_logical_type {
    return bridge.duckdb_create_struct_type(
        @constCast(&[_]bridge.duckdb_logical_type{ duckdbext.LogicalType.varchar.toInternal().ptr, duckdbext.LogicalType.bigint.toInternal().ptr, duckdbext.LogicalType.varchar.toInternal().ptr }),
        @constCast(@alignCast(@ptrCast(&[_][*c]u8{ @constCast("hash"), @constCast("size_bytes"), @constCast("hash_function_name") }))),
        3,
    );
}

pub fn files_type() bridge.duckdb_logical_type {
    return bridge.duckdb_create_list_type(
        bridge.duckdb_create_struct_type(
            @constCast(&[_]bridge.duckdb_logical_type{ duckdbext.LogicalType.varchar.toInternal().ptr, duckdbext.LogicalType.varchar.toInternal().ptr, digest_type(), duckdbext.LogicalType.bool.toInternal().ptr }),
            @constCast(@alignCast(@ptrCast(&[_][*c]u8{ @constCast("path"), @constCast("symlink_target_path"), @constCast("digest"), @constCast("is_tool") }))),
            4,
        ),
    );
}

pub fn metrics_type() bridge.duckdb_logical_type {
    return bridge.duckdb_create_struct_type(
        @constCast(&[_]bridge.duckdb_logical_type{
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
            duckdbext.LogicalType.bigint.toInternal().ptr,
            duckdbext.LogicalType.bigint.toInternal().ptr,
            duckdbext.LogicalType.bigint.toInternal().ptr,
            duckdbext.LogicalType.bigint.toInternal().ptr,
            duckdbext.LogicalType.bigint.toInternal().ptr,
            duckdbext.LogicalType.bigint.toInternal().ptr,
            duckdbext.LogicalType.bigint.toInternal().ptr,
            duckdbext.LogicalType.bigint.toInternal().ptr,
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
}
