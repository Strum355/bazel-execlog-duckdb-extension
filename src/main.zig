const std = @import("std");
const duckdbext = @import("duckdbext.zig");
const proto = @import("proto/protos.pb.zig");
const protobuf = @import("protobuf");
const zstd = @import("std").compress.zstd;
const c = @cImport(@cInclude("duckdb.h"));
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

    while (true) {
        const spawn = try initData.reader.getSpawnExec() orelse break;
        std.debug.print("GOT EXEC {s} {s}\n", .{ spawn.target_label.getSlice(), spawn.mnemonic.getSlice() });
    }

    // TODO: split this out per DataChunk size

    initData.done = true;

    // const repeated = try repeat(allocator, "🐥", 3);
    // defer allocator.free(repeated);
    // for (0..10) |i| {
    //     chunk.vector(0).assignStringElement(i, "🐥");
    // }
    // chunk.setSize(10);
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
