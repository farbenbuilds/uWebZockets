export interface SharedMemoryExports {
    readonly memory: WebAssembly.Memory;
    shared_acquire(length: number): bigint;
    shared_pointer(handle: bigint): number;
    shared_commit(handle: bigint, length: number): bigint;
    shared_release(handle: bigint): number;
}

export class SharedMemoryBridge {
    readonly exports: SharedMemoryExports;

    constructor(exports: SharedMemoryExports) {
        this.exports = exports;
    }

    acquire(length: number): SharedLease {
        if (!Number.isSafeInteger(length) || length <= 0) {
            throw new RangeError("shared-memory length must be a positive integer");
        }
        const handle = this.exports.shared_acquire(length);
        if (handle === 0n) throw new Error("shared-memory region is exhausted");
        return new SharedLease(this.exports, handle, length);
    }
}

export class SharedLease {
    private readonly exports: SharedMemoryExports;
    private handle: bigint;
    private length: number;

    constructor(exports: SharedMemoryExports, handle: bigint, length: number) {
        this.exports = exports;
        this.handle = handle;
        this.length = length;
    }

    view(): Uint8Array {
        this.require_live();
        const pointer = this.exports.shared_pointer(this.handle);
        if (pointer === 0) throw new Error("shared-memory handle is stale");
        return new Uint8Array(this.exports.memory.buffer, pointer, this.length);
    }

    commit(length: number): Uint8Array {
        this.require_live();
        if (!Number.isSafeInteger(length) || length < 0 || length > this.length) {
            throw new RangeError("committed length exceeds the lease");
        }
        const handle = this.exports.shared_commit(this.handle, length);
        if (handle === 0n) throw new Error("shared-memory commit failed");
        this.handle = handle;
        this.length = length;
        return this.view();
    }

    capnp_segment(max_words: number): Uint8Array {
        const message = this.view();
        if (message.byteLength < 8 || message.byteLength % 8 !== 0) {
            throw new Error("invalid Cap'n Proto envelope length");
        }
        const header = new DataView(message.buffer, message.byteOffset, 8);
        if (header.getUint32(0, true) !== 0) {
            throw new Error("only single-segment Cap'n Proto messages are supported");
        }
        const word_count = header.getUint32(4, true);
        if (word_count > max_words || word_count * 8 !== message.byteLength - 8) {
            throw new Error("invalid Cap'n Proto segment bounds");
        }
        return message.subarray(8);
    }

    release(): void {
        if (this.handle === 0n) return;
        const handle = this.handle;
        this.handle = 0n;
        this.length = 0;
        if (this.exports.shared_release(handle) !== 0) {
            throw new Error("shared-memory release rejected a stale handle");
        }
    }

    private require_live(): void {
        if (this.handle === 0n) throw new Error("shared-memory lease is released");
    }
}
