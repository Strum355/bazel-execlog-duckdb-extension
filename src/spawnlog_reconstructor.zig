const std = @import("std");
const protodelim = @import("protodelim.zig");
const proto = @import("proto/protos.pb.zig");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;

pub fn Reconstructor(comptime ReaderType: type) type {
    return struct {
        reader: protodelim.Reader(ReaderType, proto.ExecLogEntry),

        files: std.hash_map.AutoHashMap(i32, proto.File),
        dirs: std.hash_map.AutoHashMap(i32, reconstructedDir),
        symlinks: std.hash_map.AutoHashMap(i32, proto.File),
        sets: std.hash_map.AutoHashMap(i32, proto.ExecLogEntry.InputSet),

        allocator: std.mem.Allocator,

        const reconstructedDir = struct { path: []const u8, files: []proto.File };

        pub fn init(reader: ReaderType, allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .reader = protodelim.Reader(ReaderType, proto.ExecLogEntry){
                    .allocator = allocator,
                    .source = reader,
                },
                .files = std.hash_map.AutoHashMap(i32, proto.File).init(allocator),
                .dirs = std.hash_map.AutoHashMap(i32, reconstructedDir).init(allocator),
                .symlinks = std.hash_map.AutoHashMap(i32, proto.File).init(allocator),
                .sets = std.hash_map.AutoHashMap(i32, proto.ExecLogEntry.InputSet).init(allocator),
            };
        }

        pub fn getSpawnExec(self: *@This()) !?proto.SpawnExec {
            while (true) {
                const entry = try self.reader.decodeOne() orelse return null;

                switch (entry.type.?) {
                    .invocation => {},
                    .file => |file| try self.files.put(entry.id, self.reconstructFile(null, file)),
                    .directory => |dir| try self.dirs.put(entry.id, self.reconstructDir(dir)),
                    .unresolved_symlink => |sym| try self.symlinks.put(entry.id, self.reconstructSymlink(sym)),
                    .input_set => |inputs| try self.sets.put(entry.id, inputs),
                    .spawn => |spawn| return self.reconstructSpawn(spawn),
                }
            }

            return null;
        }

        fn reconstructSpawn(self: *@This(), spawn: proto.ExecLogEntry.Spawn) ?proto.SpawnExec {
            const inputs = self.reconstructInputs(spawn.input_set_id) catch return null;
            const tools = self.reconstructInputs(spawn.tool_set_id) catch return null;

            var all_inputs = std.ArrayList(proto.File).initCapacity(self.allocator, inputs.order.len) catch return null;
            var listed_outputs = std.ArrayList(protobuf.ManagedString).init(self.allocator);
            var actual_outputs = std.ArrayList(proto.File).init(self.allocator);

            const s = proto.SpawnExec{
                .command_args = spawn.args,
                .environment_variables = spawn.env_vars,
                .target_label = spawn.target_label,
                .mnemonic = spawn.mnemonic,
                .exit_code = spawn.exit_code,
                .status = spawn.status,
                .runner = spawn.runner,
                .cache_hit = spawn.cache_hit,
                .remotable = spawn.remotable,
                .cacheable = spawn.cacheable,
                .remote_cacheable = spawn.remote_cacheable,
                .timeout_millis = spawn.timeout_millis,
                .metrics = spawn.metrics,
                .platform = spawn.platform,
                .digest = spawn.digest,
                .inputs = all_inputs,
                .listed_outputs = listed_outputs,
                .actual_outputs = actual_outputs,
            };

            for (inputs.order) |path| {
                var file = inputs.inputs.get(path) orelse return null;
                if (tools.inputs.contains(path)) {
                    file.is_tool = true;
                }
                all_inputs.append(file) catch return null;
            }

            for (spawn.outputs.items) |output| {
                switch (output.type.?) {
                    .file_id => |file_id| {
                        const f = self.files.get(file_id) orelse return null;
                        listed_outputs.append(f.path) catch return null;
                        actual_outputs.append(f) catch return null;
                    },
                    .directory_id => |dir_id| {
                        const d = self.dirs.get(dir_id) orelse return null;
                        listed_outputs.append(protobuf.ManagedString.managed(d.path)) catch return null;
                        for (d.files) |file| {
                            actual_outputs.append(file) catch return null;
                        }
                    },
                    .unresolved_symlink_id => |sym_id| {
                        const sym = self.symlinks.get(sym_id) orelse return null;
                        listed_outputs.append(sym.path) catch return null;
                        actual_outputs.append(sym) catch return null;
                    },
                    .invalid_output_path => |invalid| {
                        listed_outputs.append(invalid) catch return null;
                    },
                }
            }

            return s;
        }

        fn reconstructInputs(self: *@This(), set_id: i32) !struct { order: [][]const u8, inputs: std.StringHashMap(proto.File) } {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var order = std.ArrayList([]const u8).init(self.allocator);
            var inputs = std.StringHashMap(proto.File).init(self.allocator);

            var sets_to_visit = std.AutoArrayHashMap(i32, struct {}).init(arena.allocator());
            // var sets_to_visit = std.ArrayList(i32).init(arena);
            var visited = std.bit_set.IntegerBitSet(65535).initEmpty();

            if (set_id != 0) {
                try sets_to_visit.put(set_id, .{});
                visited.set(@intCast(set_id));
            }

            while (sets_to_visit.count() > 0) {
                const current_id = sets_to_visit.iterator().keys[0];
                sets_to_visit.orderedRemoveAt(0);
                const set = self.sets.get(current_id) orelse unreachable;

                for (set.file_ids.items) |file_id| {
                    if (!visited.isSet(@intCast(file_id))) {
                        visited.set(@intCast(file_id));
                        const f = self.files.get(file_id) orelse unreachable;
                        try order.append(f.path.getSlice());
                        try inputs.put(f.path.getSlice(), f);
                    }
                }

                for (set.directory_ids.items) |dir_id| {
                    if (!visited.isSet(@intCast(dir_id))) {
                        visited.set(@intCast(dir_id));
                        const d = self.dirs.get(dir_id) orelse unreachable;
                        for (d.files) |f| {
                            try order.append(f.path.getSlice());
                            try inputs.put(f.path.getSlice(), f);
                        }
                    }
                }

                for (set.unresolved_symlink_ids.items) |sym_id| {
                    if (!visited.isSet(@intCast(sym_id))) {
                        visited.set(@intCast(sym_id));
                        const s = self.symlinks.get(sym_id) orelse unreachable;
                        try order.append(s.path.getSlice());
                        try inputs.put(s.path.getSlice(), s);
                    }
                }

                for (set.transitive_set_ids.items) |sid| {
                    if (!visited.isSet(@intCast(sid))) {
                        visited.set(@intCast(sid));
                        try sets_to_visit.put(sid, .{});
                    }
                }
            }

            return .{
                .order = order.items,
                .inputs = inputs,
            };
        }

        fn reconstructDir(self: *@This(), dir: proto.ExecLogEntry.Directory) reconstructedDir {
            var files_in_dir = std.ArrayList(proto.File).initCapacity(self.allocator, dir.files.items.len) catch unreachable;
            for (dir.files.items) |file| {
                files_in_dir.appendAssumeCapacity(self.reconstructFile(dir, file));
            }
            return reconstructedDir{
                .files = files_in_dir.items,
                .path = dir.path.getSlice(),
            };
        }

        fn reconstructFile(self: *@This(), parent: ?proto.ExecLogEntry.Directory, file: proto.ExecLogEntry.File) proto.File {
            var f = proto.File{
                .digest = file.digest,
            };
            if (parent) |p| {
                f.path = ManagedString.managed(std.fs.path.join(self.allocator, &.{ p.path.getSlice(), file.path.getSlice() }) catch |err| @panic(std.fmt.allocPrint(self.allocator, "error joining paths {s} and {s}: {any}", .{
                    p.path.getSlice(), file.path.getSlice(), err,
                }) catch unreachable));
            } else {
                f.path = file.path;
            }
            return f;
        }

        fn reconstructSymlink(_: *@This(), link: proto.ExecLogEntry.UnresolvedSymlink) proto.File {
            return .{
                .path = link.path,
                .symlink_target_path = link.target_path,
            };
        }
    };
}
