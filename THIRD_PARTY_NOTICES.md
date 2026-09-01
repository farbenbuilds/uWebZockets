# Third-Party Notices

µWebZockets includes or links the following third-party software:

| Component | Version or revision | License |
| --- | --- | --- |
| zslay | 0.1.5 | MIT |
| libxev | 9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf | MIT |
| BoringSSL | 7c1efd8d6ffb36a57feba44e8c73cf674801f3cb | ISC-style and component licenses |
| Fiat Crypto (via BoringSSL) | BoringSSL revision above | Apache-2.0 |
| lsquic | 4.9.3 | MIT and bundled component licenses |
| ls-qpack | 2.7.0 | MIT |
| ls-hpack | 2.3.5 | MIT |
| libdeflate | 1.26 | MIT |
| zlib | system-provided | zlib License |
| h1spec | f0a5650a20c575fbea0f7179a3a9cfa50f20ba6e | MIT |

The zslay and libxev license texts are in the licenses directory. C/C++ sources
are selected by immutable Zig package hashes; the repository's submodules are
retained for auditability. Binary release archives copy every license needed by
the included static libraries into `licenses/vendor`, including Fiat Crypto's
license and author attribution. zlib is linked from the
target toolchain and is not copied into release archives; downstream
applications must satisfy its license and linkage terms.

The build applies `patches/lsquic_h3_message_error.patch` to generated lsquic
sources so positive header-callback results remain `H3_MESSAGE_ERROR` stream
errors as documented by the pinned API. The h1spec CI job applies
`patches/h1spec_deno_cleanup.patch` only to close and unreference completed test
connections. Both upstream submodules remain unchanged.
