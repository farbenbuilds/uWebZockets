const std = @import("std");
const identity = @import("identity.zig");
const session = @import("session.zig");

/// Full CONNECT identifiers remain scoped to their connection generation.
pub const Key = struct {
    connection: identity.ConnectionHandle,
    session_id: u64,
};

const Map = std.AutoHashMapUnmanaged(Key, session.SessionHandle);
const Context = std.hash_map.AutoContext(Key);

/// Startup geometry is checked before the hash map allocates its slabs.
pub const InitError = std.mem.Allocator.Error || error{InvalidCapacity};
/// Every rejected insertion preserves existing associations.
pub const InsertError = error{ InvalidIdentity, DuplicateSession, CapacityExceeded };

/// Worker-local lookup with all storage reserved during startup.
///
/// The caller owns session records and guarantees that distinct keys do not
/// share a live handle. Do not copy this index after initialization.
pub const Index = struct {
    map: Map = .empty,
    limit: usize,
    removals_since_rehash: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limit: usize) InitError!Index {
        if (!valid_capacity(limit)) return error.InvalidCapacity;
        var index = Index{ .limit = limit };
        errdefer index.map.deinit(allocator);
        try index.map.ensureTotalCapacity(allocator, @intCast(limit));
        return index;
    }

    /// Native close must retire every mapping before its storage is released.
    pub fn deinit(index: *Index, allocator: std.mem.Allocator) void {
        std.debug.assert(index.map.count() == 0);
        index.map.deinit(allocator);
    }

    pub fn insert(index: *Index, key: Key, handle: session.SessionHandle) InsertError!void {
        if (key.connection.generation == 0 or !session.valid_session_id(key.session_id) or
            handle.generation == 0 or handle.index >= index.limit) return error.InvalidIdentity;
        if (index.map.contains(key)) return error.DuplicateSession;
        if (index.map.count() >= index.limit) return error.CapacityExceeded;
        index.map.putAssumeCapacityNoClobber(key, handle);
    }

    pub fn find(index: *const Index, key: Key) ?session.SessionHandle {
        return index.map.get(key);
    }

    /// A stale close cannot retire a later owner of the same connection/SID.
    pub fn remove(index: *Index, key: Key, expected: session.SessionHandle) bool {
        const actual = index.map.get(key) orelse return false;
        if (!std.meta.eql(actual, expected)) return false;
        if (!index.map.remove(key)) return false;
        index.removals_since_rehash += 1;
        const interval = @max(1, (index.map.capacity() - index.limit) / 2);
        if (index.removals_since_rehash >= interval) {
            // Preserve empty buckets before churn can turn every miss into a full scan.
            index.map.rehash(Context{});
            index.removals_since_rehash = 0;
        }
        return true;
    }

    pub fn count(index: *const Index) usize {
        return index.map.count();
    }
};

fn valid_capacity(limit: usize) bool {
    if (limit == 0 or limit > std.math.maxInt(Map.Size)) return false;
    const needed = (@as(u64, @intCast(limit)) * 100) / std.hash_map.default_max_load_percentage + 1;
    const buckets = std.math.ceilPowerOfTwo(u64, @max(needed, 8)) catch return false;
    if (buckets > @as(u64, 1) << 31) return false;
    const bucket_bytes = @sizeOf(Key) + @sizeOf(session.SessionHandle) + 1;
    // Bound std's header and the alignment between metadata, keys and values.
    const overhead = 4 * @sizeOf(usize) + 3 * @alignOf(Key) + 3 * @alignOf(session.SessionHandle);
    return buckets <= (std.math.maxInt(usize) - overhead) / bucket_bytes;
}
