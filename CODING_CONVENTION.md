# µWebZockets Coding Conventions

These conventions adapt the spirit of the Linux Kernel Coding Style to Zig 0.16.0, focusing on pragmatism, performance, and readability.

## 1. General Rules
- **No Emojis**: Emojis are strictly forbidden anywhere in the codebase, including documentation, comments, and commit messages.
- **`zig fmt`**: All code must pass `zig fmt`. While Linux style has specific brace rules, Zig's formatter is the final authority on indentation (4 spaces) and brace placement.
- **Short and Readable Comments**: Avoid telling *how* the code works; the code should be clear enough. Comment *why* a particular approach was taken, especially for non-obvious performance optimizations or network protocol edge cases.

## 2. Control Flow & Linux Style Adaptations
- **Early Returns & Minimal Indentation**: Prefer returning early to avoid deep nesting. Keep the "happy path" un-indented.
  ```zig
  // Bad
  if (condition) {
      // ... do work ...
  } else {
      return error.Failed;
  }

  // Good
  if (!condition) return error.Failed;
  // ... do work ...
  ```
- **Control Flow Spacing**: Put a space after keywords (`if`, `switch`, `while`, `for`).
- **Variable Scoping**: Declare variables as close to their first use as possible.
- **Switch Statements**: Use `switch` over long `if/else` chains. Exhaustive switching is a Zig strength; leverage it.

## 3. Data-Oriented Design (DoD) & Functional Programming
- **Zero Object-Oriented Programming (OOP)**: OOP is strictly forbidden. Do not try to emulate classes or bind hidden state to behavior. Separate pure data structures from the functions that transform them.
- **Pure Functions**: Favor pure functions that take explicit inputs and return explicit outputs without side effects. Pass state explicitly rather than relying on hidden contexts.
- **Data Locality**: Organize data for cache efficiency. Prefer Struct of Arrays (SoA) via `std.MultiArrayList` over Array of Structs (AoS) for large collections of entities processed in bulk.
- **Zero Allocations & Purity**: Network fast-paths must not allocate dynamically. Functional pipelines (e.g., map/filter concepts) must be implemented via zero-allocation iterators or comptime metaprogramming, never generating intermediate heap allocations.
- **Alignment and Padding**: Be conscious of struct sizes and padding. Order struct fields from largest to smallest to minimize padding, unless a specific memory layout is required for C interop or hardware constraints.

## 4. Naming Conventions (Linux Style Override)
- **File Naming**: Linux file naming (`snake_case`) is strictly enforced for all files.
- **Functions & Variables**: `snake_case` is strictly enforced for all functions and variables to align with Linux kernel styling preferences, explicitly overriding standard Zig `camelCase`.
- **Types**: `PascalCase` for structs, enums, unions, and error sets (Standard Zig).
- **C Interop**: When wrapping C libraries (BoringSSL, libsquic), preserve the original C names in the raw bindings, but provide a clean `snake_case` Zig wrapper for the public API.

## 5. C Interop & FFI
- Use `@cImport` judiciously, or prefer translating C headers ahead-of-time using `translate-c` for better compilation speeds and type safety.
- Clearly separate raw C bindings from idiomatic Zig wrappers in the directory structure (e.g., `src/c/` or `src/ffi/`).

## 6. Error Handling
- Use Zig's native error sets (`!Type`).
- Never swallow errors silently. If an error is expected and ignored, document *why* with a comment.
- Use `catch unreachable` only when you can mathematically prove the error will never occur, and document the proof.
