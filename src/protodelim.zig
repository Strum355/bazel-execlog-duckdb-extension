const zstd = @import("std").compress.zstd;
const std = @import("std");

pub fn Reader(
    comptime ReaderType: type,
    comptime ProtoType: type,
) type {
    return struct {
        const maxVarintLen = 10;

        var sizearray = std.mem.zeroes([maxVarintLen]u8);

        source: ReaderType,
        allocator: std.mem.Allocator,

        pub const Error = ReaderType.Error || VarintError || error{EndOfStream};

        // can we use Error type here?
        pub fn decodeOne(self: *@This()) !?ProtoType {
            var j: u8 = 0;

            var reader = self.source.reader();

            for (0..maxVarintLen) |i| {
                const mb = reader.readByte();
                if (mb == error.EndOfStream and i != 0) {
                    break;
                }
                const b = mb catch |err| switch (err) {
                    error.EndOfStream => return null,
                    else => return err,
                };
                sizearray[i] = b;
                j += 1;
                if (b < 0x80) {
                    break;
                }
            }

            const size = try consumeVarint(sizearray[0..j]);

            const buffer = try self.allocator.alloc(u8, size);
            defer self.allocator.free(buffer);
            try reader.readNoEof(buffer);
            return try ProtoType.decode(buffer, self.allocator);
        }
    };
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
