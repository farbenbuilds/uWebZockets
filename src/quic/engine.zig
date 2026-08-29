pub const available = false;

// The previous adapter could not uphold transport ownership guarantees.
pub const QuicEngine = struct {
    pub fn init() error{Http3NotImplemented}!*QuicEngine {
        return error.Http3NotImplemented;
    }
};
