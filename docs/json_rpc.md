# JSON-RPC 2.0

`json_rpc.Service` is a type-safe, fixed-capacity JSON-RPC 2.0 registry. Mount
it on any `App` with one line, or call `dispatch` directly from another
transport. The protocol layer imports only Zig's standard library.

```zig
const AddParams = struct { a: i64, b: i64 };
const AddResult = struct { sum: i64 };

fn add(params: AddParams) uz.json_rpc.HandlerError!AddResult {
    return .{ .sum = params.a + params.b };
}

var rpc = uz.json_rpc.Service{};
try rpc.register_typed("math.add", AddParams, AddResult, add);
_ = try app.rpc("/rpc", &rpc);
```

## Protocol behavior

- Clients send exactly one `Content-Type: application/json` or
  `application/json-rpc` header.
- Single calls, notifications, and batches are supported. Notification-only
  requests return HTTP 204; protocol responses use HTTP 200.
- Complete JSON syntax is validated before a batch invokes its first procedure.
- Method names are copied during registration, and mounting seals the registry.
- Parameters are borrowed only for the callback. Results serialize into bounded
  caller- or service-owned output storage.
- `register_context` and `register_typed_context` carry explicit application
  state. `register` supports custom decoding, and `Call.fail` returns an
  application-defined error.

## Capacities

Typed adapters use 4 KiB of fixed stack scratch for decoded parameters. Use the
lower-level `register` API with `Call.parse_params` and an explicit allocator
when a parameter type can exceed that bound.
`uz.json_rpc.configured_service(max_procedures, method_storage_capacity,
response_capacity)` returns a specialized service type with defaults of 64
procedures, 4 KiB of copied method names, and a 16 KiB response.

One mounted service owns one HTTP response buffer and belongs to one event
loop. Create one service per cluster worker; a service shared across workers
would race on its response storage.
