pub const available = false;

// HTTP/3 streams remain unavailable until a bounded QPACK path exists.
pub const QuicStream = struct {
    pub fn init() error{Http3NotImplemented}!QuicStream {
        return error.Http3NotImplemented;
    }
};
