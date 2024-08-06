const std = @import("std");
const duckdbext = @import("duckdbext.zig");
const proto = @import("proto/protos.pb.zig");
const protobuf = @import("protobuf");
const zstd = @import("std").compress.zstd;
const c = @cImport(@cInclude("duckdb.h"));

const InitData = struct {
    done: bool,
};

const BindData = struct { gpa: std.heap.GeneralPurposeAllocator(.{}), file: std.fs.File, compressedReader: zstd.Decompressor(std.fs.File.Reader) };

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
export fn compact_execlog_init_zig(db: *anyopaque) void {
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

    compact_execlog_init(&conn);
}

// split for test injection
fn compact_execlog_init(conn: *duckdbext.Connection) void {
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

test compact_execlog_init {
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

    compact_execlog_init(&conn);
    // todo exec test query
}

fn bind(info: *duckdbext.BindInfo, data: *BindData) !void {
    info.addResultColumn("quacks", .varchar);

    var pathParam: duckdbext.Value = info.getParameter(0) orelse {
        info.setErr("path to execlog required");
        return;
    };
    defer pathParam.deinit();

    const path: []u8 = std.mem.span(pathParam.toString());
    // defer c.duckdb_free(&path);

    data.gpa = std.heap.GeneralPurposeAllocator(.{}){};
    data.file = try std.fs.cwd().openFile(path, .{});

    const zstdBuffer = try data.gpa.allocator().create([zstd.DecompressorOptions.default_window_buffer_len]u8);
    data.compressedReader = zstd.decompressor(data.file.reader(), .{ .window_buffer = zstdBuffer });
}

fn init(_: *duckdbext.InitInfo, data: *InitData) !void {
    data.done = false;
}

const maxVarintLen = 10;

fn func(chunk: *duckdbext.DataChunk, initData: *InitData, bindData: *BindData) !void {
    if (initData.done) {
        chunk.setSize(0);
        bindData.file.close();
        _ = bindData.gpa.deinit();
        return;
    }

    // TODO: split this out per DataChunk size

    const allocator = bindData.gpa.allocator();

    const reader = bindData.compressedReader.reader();

    var sizearray = std.mem.zeroes([maxVarintLen]u8);

    outer: while (true) {
        var j: u8 = 0;
        for (0..maxVarintLen) |i| {
            const mb = reader.readByte();
            if (mb == error.EndOfStream and i != 0) {
                break;
            }
            const b = mb catch |err| switch (err) {
                error.EndOfStream => break :outer,
                else => return err,
            };
            sizearray[i] = b;
            j += 1;
            if (b < 0x80) {
                break;
            }
        }

        const size = try consumeVarint(sizearray[0..j]);

        const buffer = try allocator.alloc(u8, size);
        defer allocator.free(buffer);
        try reader.readNoEof(buffer);

        const execlogEntry = try proto.ExecLogEntry.decode(buffer, allocator);
        switch (execlogEntry.type.?) {
            .invocation => std.debug.print("got invocation {d} {s}\n", .{ execlogEntry.id, execlogEntry.type.?.invocation.hash_function_name.getSlice() }),
            else => std.debug.print("execlog entry {d} {any}\n", .{ execlogEntry.id, execlogEntry.type }),
        }
        defer execlogEntry.deinit();

        // initData.done = true;

        // const repeated = try repeat(allocator, "🐥", 3);
        // defer allocator.free(repeated);
        // for (0..10) |i| {
        //     chunk.vector(0).assignStringElement(i, "🐥");
        // }
        // chunk.setSize(10);
    }
}

pub const VarintError = error{
    CodeTruncated,
    CodeOverflow,
};

// proto library has a shorter one, but its not exposed
pub fn consumeVarint(b: []const u8) VarintError!u64 {
    var v: u64 = 0;
    var y: u64 = 0;

    if (b.len == 0) {
        return VarintError.CodeTruncated;
    }

    v = b[0];
    if (v < 0x80) {
        return v;
    }
    v -= 0x80;

    inline for (1..9) |i| {
        if (b.len <= i) {
            return VarintError.CodeTruncated;
        }

        y = b[i];
        v += y << (7 * i);

        if (y < 0x80) {
            return v;
        }
        v -= 0x80 << (7 * i);
    }

    if (b.len <= 9) {
        return VarintError.CodeTruncated;
    }

    y = b[9];
    v += y << 63;
    if (y < 2) {
        return v;
    }

    return VarintError.CodeOverflow;
}
