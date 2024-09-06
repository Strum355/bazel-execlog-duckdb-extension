const std = @import("std");
const duckdbext = @import("duckdbext.zig");
const proto = @import("proto/protos.pb.zig");
const gproto = @import("proto/google/protobuf.pb.zig");
const protobuf = @import("protobuf");
const zstd = @import("std").compress.zstd;
const bridge = @cImport(@cInclude("duckdb.h"));
const types = @import("types.zig");
const Reconstructor = @import("spawnlog_reconstructor.zig").Reconstructor;

const InitData = struct {
    done: bool,
    // can i clean this up somehow
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    proto_alloc: std.heap.ArenaAllocator,
    file: std.fs.File,
    reader: Reconstructor(zstd.Decompressor(std.fs.File.Reader)),
    zstdBuffer: *[zstd.DecompressorOptions.default_window_buffer_len]u8,
};

const BindData = struct {
    path: []u8,
};

export fn compact_execlog_version_zig() [*:0]const u8 {
    return duckdbext.duckdbVersion();
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

fn bind(info: *duckdbext.BindInfo, data: *BindData) !void {
    var pathParam: duckdbext.Value = info.getParameter(0) orelse {
        info.setErr("path to execlog required");
        return;
    };
    defer pathParam.deinit();
    // defer bridge.duckdb_free(&path);

    data.path = std.mem.span(pathParam.toString());

    bridge.duckdb_bind_add_result_column(info.ptr, "command_args", types.varchar_list_type());
    bridge.duckdb_bind_add_result_column(info.ptr, "environment_variables", types.envvars_type());
    bridge.duckdb_bind_add_result_column(info.ptr, "platform", types.platform_properties_type());
    bridge.duckdb_bind_add_result_column(info.ptr, "inputs", types.files_type());
    bridge.duckdb_bind_add_result_column(info.ptr, "listed_outputs", types.varchar_list_type());
    bridge.duckdb_bind_add_result_column(info.ptr, "remotable", duckdbext.LogicalType.bool.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "cacheable", duckdbext.LogicalType.bool.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "timeout_millis", duckdbext.LogicalType.bigint.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "mnemonic", duckdbext.LogicalType.varchar.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "actual_outputs", types.files_type());
    bridge.duckdb_bind_add_result_column(info.ptr, "runner", duckdbext.LogicalType.varchar.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "cache_hit", duckdbext.LogicalType.bool.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "status", duckdbext.LogicalType.varchar.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "exit_code", duckdbext.LogicalType.int.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "remote_cacheable", duckdbext.LogicalType.bool.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "target_label", duckdbext.LogicalType.varchar.toInternal().ptr);
    bridge.duckdb_bind_add_result_column(info.ptr, "digest", types.digest_type());
    bridge.duckdb_bind_add_result_column(info.ptr, "metrics", types.metrics_type());
}

fn init(info: *duckdbext.InitInfo, data: *InitData) !void {
    data.done = false;
    const bindData: *BindData = @ptrCast(@alignCast(bridge.duckdb_init_get_bind_data(info.ptr)));

    data.gpa = std.heap.GeneralPurposeAllocator(.{}){};
    data.file = try std.fs.cwd().openFile(bindData.path, .{});
    data.proto_alloc = std.heap.ArenaAllocator.init(data.gpa.allocator());

    const zstdBuffer = try data.gpa.allocator().create([zstd.DecompressorOptions.default_window_buffer_len]u8);
    data.zstdBuffer = zstdBuffer;
    data.reader = Reconstructor(zstd.Decompressor(std.fs.File.Reader)).init(zstd.decompressor(data.file.reader(), .{ .window_buffer = zstdBuffer }), data.proto_alloc.allocator());
}

fn func(chunk: *duckdbext.DataChunk, initData: *InitData, _: *BindData) !void {
    if (initData.done) {
        chunk.setSize(0);
        initData.file.close();
        initData.gpa.allocator().destroy(initData.zstdBuffer);
        initData.proto_alloc.deinit();
        _ = initData.gpa.deinit();
        return;
    }

    const max_rows = bridge.duckdb_vector_size();

    // List offsets for list-typed columns.
    var offsets: struct {
        row: u64 = 0,
        command_args: u64 = 0,
        envvars: u64 = 0,
        platform: u64 = 0,
        inputs: u64 = 0,
        listed_outputs: u64 = 0,
        actual_outputs: u64 = 0,
    } = .{};

    while (offsets.row < max_rows - 1) : (offsets.row += 1) {
        const spawn: proto.SpawnExec = try initData.reader.getSpawnExec() orelse {
            initData.done = true;
            break;
        };

        // command_args
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 0);
            const list_entries_vector = @as([*]bridge.duckdb_list_entry, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            const list_entry = &list_entries_vector[offsets.row];
            list_entry.length = spawn.command_args.items.len;
            list_entry.offset = offsets.command_args;
            const current_offset = offsets.command_args;
            offsets.command_args += spawn.command_args.items.len;

            _ = bridge.duckdb_list_vector_reserve(column, offsets.command_args);
            _ = bridge.duckdb_list_vector_set_size(column, offsets.command_args);

            const child_vector = bridge.duckdb_list_vector_get_child(column);
            for (spawn.command_args.items, 0..) |arg, i| {
                _ = bridge.duckdb_vector_assign_string_element_len(child_vector, current_offset + i, arg.getSlice().ptr, arg.getSlice().len);
            }
        }

        // environment_variables
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 1);
            const list_entries_vector = @as([*]bridge.duckdb_list_entry, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            const list_entry = &list_entries_vector[offsets.row];
            list_entry.length = spawn.environment_variables.items.len;
            list_entry.offset = offsets.envvars;
            const current_offset = offsets.envvars;
            offsets.envvars += spawn.environment_variables.items.len;

            _ = bridge.duckdb_list_vector_reserve(column, offsets.envvars);
            _ = bridge.duckdb_list_vector_set_size(column, offsets.envvars);

            const child_vector = bridge.duckdb_list_vector_get_child(column);
            for (spawn.environment_variables.items, 0..) |env, i| {
                // https://discord.com/channels/909674491309850675/1148659944669851849/1150416608251105390
                // index 0 = name field, index 1 = value field
                const name_field = bridge.duckdb_struct_vector_get_child(child_vector, 0);
                _ = bridge.duckdb_vector_assign_string_element_len(name_field, current_offset + i, env.name.getSlice().ptr, env.name.getSlice().len);
                const value_field = bridge.duckdb_struct_vector_get_child(child_vector, 1);
                _ = bridge.duckdb_vector_assign_string_element_len(value_field, current_offset + i, env.value.getSlice().ptr, env.value.getSlice().len);
            }
        }

        // platform
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 2);
            const list_entries_vector = @as([*]bridge.duckdb_list_entry, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            const list_entry = &list_entries_vector[offsets.row];
            if (spawn.platform) |platforms| {
                list_entry.length = platforms.properties.items.len;
                list_entry.offset = offsets.platform;
                const current_offset = offsets.platform;
                offsets.platform += platforms.properties.items.len;

                _ = bridge.duckdb_list_vector_reserve(column, offsets.platform);
                _ = bridge.duckdb_list_vector_set_size(column, offsets.platform);

                const child_vector = bridge.duckdb_list_vector_get_child(column);
                for (platforms.properties.items, 0..) |platform, i| {
                    // https://discord.com/channels/909674491309850675/1148659944669851849/1150416608251105390
                    // index 0 = name field, index 1 = value field
                    const name_field = bridge.duckdb_struct_vector_get_child(child_vector, 0);
                    _ = bridge.duckdb_vector_assign_string_element_len(name_field, current_offset + i, platform.name.getSlice().ptr, platform.name.getSlice().len);
                    const value_field = bridge.duckdb_struct_vector_get_child(child_vector, 1);
                    _ = bridge.duckdb_vector_assign_string_element_len(value_field, current_offset + i, platform.value.getSlice().ptr, platform.value.getSlice().len);
                }
            }
        }

        // inputs
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 3);
            const list_entries_vector = @as([*]bridge.duckdb_list_entry, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            const list_entry = &list_entries_vector[offsets.row];
            list_entry.length = spawn.inputs.items.len;
            list_entry.offset = offsets.inputs;
            const current_offset = offsets.inputs;
            offsets.inputs += spawn.inputs.items.len;

            _ = bridge.duckdb_list_vector_reserve(column, offsets.inputs);
            _ = bridge.duckdb_list_vector_set_size(column, offsets.inputs);

            const child_vector = bridge.duckdb_list_vector_get_child(column);
            for (spawn.inputs.items, 0..) |input, i| {
                const path_field = bridge.duckdb_struct_vector_get_child(child_vector, 0);
                _ = bridge.duckdb_vector_assign_string_element_len(path_field, current_offset + i, input.path.getSlice().ptr, input.path.getSlice().len);
                
                const symlink_path_field = bridge.duckdb_struct_vector_get_child(child_vector, 1);
                _ = bridge.duckdb_vector_assign_string_element_len(symlink_path_field, current_offset + i, input.symlink_target_path.getSlice().ptr, input.symlink_target_path.getSlice().len);
                
                const digest_field = bridge.duckdb_struct_vector_get_child(child_vector, 2);
                if (input.digest) |digest| {
                    const hash_field = bridge.duckdb_struct_vector_get_child(digest_field, 0);
                    _ = bridge.duckdb_vector_assign_string_element_len(hash_field, current_offset + i, digest.hash.getSlice().ptr, digest.hash.getSlice().len);
                    
                    const size_bytes_field = bridge.duckdb_struct_vector_get_child(digest_field, 1);
                    const size_bytes_data = @as([*]i64, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(size_bytes_field))))[0..];
                    size_bytes_data[current_offset + i] = digest.size_bytes;

                    const hash_fn_name_field = bridge.duckdb_struct_vector_get_child(digest_field, 2);
                    _ = bridge.duckdb_vector_assign_string_element_len(hash_fn_name_field, current_offset + i, digest.hash_function_name.getSlice().ptr, digest.hash_function_name.getSlice().len);
                }

                const is_tool_field = bridge.duckdb_struct_vector_get_child(child_vector, 3);
                const is_tool_data = @as([*]bool, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(is_tool_field))))[0..];
                is_tool_data[current_offset + i] = input.is_tool;
            }
        }

        // listed_outputs
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 4);
            const list_entries_vector = @as([*]bridge.duckdb_list_entry, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            const list_entry = &list_entries_vector[offsets.row];
            list_entry.length = spawn.listed_outputs.items.len;
            list_entry.offset = offsets.listed_outputs;
            const current_offset = offsets.listed_outputs;
            offsets.listed_outputs += spawn.listed_outputs.items.len;

            _ = bridge.duckdb_list_vector_reserve(column, offsets.inputs);
            _ = bridge.duckdb_list_vector_set_size(column, offsets.inputs);

            const child_vector = bridge.duckdb_list_vector_get_child(column);
            for (spawn.listed_outputs.items, 0..) |output, i| {
                _ = bridge.duckdb_vector_assign_string_element_len(child_vector, current_offset + i, output.getSlice().ptr, output.getSlice().len);
            }
        }

        // remoteable
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 5);
            const remoteable = @as([*]bool, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            remoteable[offsets.row] = spawn.remotable;
        }

        // cacheable
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 6);
            const cacheable = @as([*]bool, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            cacheable[offsets.row] = spawn.cacheable;
        }

        // timeout_millis
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 7);
            const timeout_millis = @as([*]i64, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            timeout_millis[offsets.row] = spawn.timeout_millis;
        }

        // mnemonic
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 8);
            _ = bridge.duckdb_vector_assign_string_element_len(column, offsets.row, spawn.mnemonic.getSlice().ptr, spawn.mnemonic.getSlice().len);
        }

        // actual_outputs
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 9);
            const list_entries_vector = @as([*]bridge.duckdb_list_entry, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            const list_entry = &list_entries_vector[offsets.row];
            list_entry.length = spawn.actual_outputs.items.len;
            list_entry.offset = offsets.actual_outputs;
            const current_offset = offsets.actual_outputs;
            offsets.actual_outputs += spawn.actual_outputs.items.len;

            _ = bridge.duckdb_list_vector_reserve(column, offsets.inputs);
            _ = bridge.duckdb_list_vector_set_size(column, offsets.inputs);

            const child_vector = bridge.duckdb_list_vector_get_child(column);
            for (spawn.actual_outputs.items, 0..) |output, i| {
                const path_field = bridge.duckdb_struct_vector_get_child(child_vector, 0);
                _ = bridge.duckdb_vector_assign_string_element_len(path_field, current_offset + i, output.path.getSlice().ptr, output.path.getSlice().len);
                
                const symlink_path_field = bridge.duckdb_struct_vector_get_child(child_vector, 1);
                _ = bridge.duckdb_vector_assign_string_element_len(symlink_path_field, current_offset + i, output.symlink_target_path.getSlice().ptr, output.symlink_target_path.getSlice().len);
                
                const digest_field = bridge.duckdb_struct_vector_get_child(child_vector, 2);
                if (output.digest) |digest| {
                    const hash_field = bridge.duckdb_struct_vector_get_child(digest_field, 0);
                    _ = bridge.duckdb_vector_assign_string_element_len(hash_field, current_offset + i, digest.hash.getSlice().ptr, digest.hash.getSlice().len);
                    
                    const size_bytes_field = bridge.duckdb_struct_vector_get_child(digest_field, 1);
                    const size_bytes_data = @as([*]i64, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(size_bytes_field))))[0..];
                    size_bytes_data[current_offset + i] = digest.size_bytes;

                    const hash_fn_name_field = bridge.duckdb_struct_vector_get_child(digest_field, 2);
                    _ = bridge.duckdb_vector_assign_string_element_len(hash_fn_name_field, current_offset + i, digest.hash_function_name.getSlice().ptr, digest.hash_function_name.getSlice().len);
                }

                const is_tool_field = bridge.duckdb_struct_vector_get_child(child_vector, 3);
                const is_tool_data = @as([*]bool, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(is_tool_field))))[0..];
                is_tool_data[current_offset + i] = output.is_tool;
            }
        }

        // runner
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 10);
            _ = bridge.duckdb_vector_assign_string_element_len(column, offsets.row, spawn.runner.getSlice().ptr, spawn.runner.getSlice().len);
        }

        // cache_hit
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 11);
            const cache_hit = @as([*]bool, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            cache_hit[offsets.row] = spawn.cache_hit;
        }

        // status
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 12);
            _ = bridge.duckdb_vector_assign_string_element_len(column, offsets.row, spawn.status.getSlice().ptr, spawn.status.getSlice().len);
        }

        // exit_code
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 13);
            const exit_code = @as([*]i32, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            exit_code[offsets.row] = spawn.exit_code;
        }

        // remote_cacheable
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 14);
            const remote_cacheable = @as([*]bool, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(column))))[0..max_rows];
            remote_cacheable[offsets.row] = spawn.remote_cacheable;
        }

        // target_label
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 15);
            _ = bridge.duckdb_vector_assign_string_element_len(column, offsets.row, spawn.target_label.getSlice().ptr, spawn.target_label.getSlice().len);
        }

        // digest
        {
            const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 16);

            if (spawn.digest) |digest| {
                const hash_field = bridge.duckdb_struct_vector_get_child(column, 0);
                _ = bridge.duckdb_vector_assign_string_element_len(hash_field, offsets.row, digest.hash.getSlice().ptr, digest.hash.getSlice().len);
                
                const size_bytes_field = bridge.duckdb_struct_vector_get_child(column, 1);
                const size_bytes_data = @as([*]i64, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(size_bytes_field))))[0..max_rows];
                size_bytes_data[offsets.row] = digest.size_bytes;

                const hash_fn_name_field = bridge.duckdb_struct_vector_get_child(column, 2);
                _ = bridge.duckdb_vector_assign_string_element_len(hash_fn_name_field, offsets.row, digest.hash_function_name.getSlice().ptr, digest.hash_function_name.getSlice().len);
            }
        }

        // metrics
        {
            inline for (std.meta.fields(proto.SpawnMetrics), 0..) |field, i| {
                const column = bridge.duckdb_data_chunk_get_vector(chunk.ptr, 17);
                if (field.type == ?gproto.Duration) {
                    const duration_field = bridge.duckdb_struct_vector_get_child(column, i);
                    const duration_data = @as([*]bridge.duckdb_interval, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(duration_field))))[0..max_rows];
                    if (@field(spawn.metrics.?, field.name)) |val| {
                        duration_data[offsets.row] = duration_to_interval(@as(gproto.Duration, val));
                    }
                } else if (field.type == i64) {
                    const duration_field = bridge.duckdb_struct_vector_get_child(column, i);
                    const duration_data = @as([*]i64, @ptrCast(@alignCast(bridge.duckdb_vector_get_data(duration_field))))[0..max_rows];
                    duration_data[offsets.row] = @field(spawn.metrics.?, field.name);
                }
            }
        }
    }
    chunk.setSize(offsets.row);
}

fn duration_to_interval(duration: gproto.Duration) bridge.duckdb_interval {
    const total_time_days = @divTrunc(duration.seconds, 60 * 60 * 24);
    const remainder_micros = @mod(duration.seconds, 60 * 60 * 24) * 1000000;
    const micros = remainder_micros + (@as(i64, duration.nanos) * 1000);
    return bridge.duckdb_interval{
        // we don't calculate duckdb_interval.months here because...why would an action take months
        .days = @intCast(total_time_days),
        .micros =  micros,
    };
}