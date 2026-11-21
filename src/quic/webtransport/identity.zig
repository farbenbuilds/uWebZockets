/// Worker-local connection identity, invalidated by slot reuse.
pub const ConnectionHandle = struct {
    index: usize = 0,
    generation: u64 = 0,
};
