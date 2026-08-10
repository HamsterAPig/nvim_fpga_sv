# Clear stale diagnostics before top-level compilation

## Problem

`slang-server` 0.2.9 (`4f33c99`) can publish exact duplicate diagnostics after
this normal client sequence:

1. Send `workspace/didChangeWatchedFiles` for the active source files.
2. Execute `slang.setBuildFile`.
3. After it succeeds, execute `slang.setTopLevel`.

The no-argument `ServerDriver::createCompilation()` used by
`slang.setBuildFile` calls `diagClient->clear()` before collecting and
publishing diagnostics. The `createCompilation(doc, top)` overload used by
`slang.setTopLevel` does not, so its parse and semantic diagnostics are
appended to the diagnostic client's existing arrays.

## Reproduction evidence

Observed with `slang-server version 0.2.9+4f33c99` in Neovim:

- The buffer had one `slang_server` client (`id=1`) and one `verible` client
  (`id=2`).
- The duplicated entries belonged to
  `nvim.lsp.slang_server.1`, so they were not merged from two clients.
- One generated Verilog file had 114 Slang diagnostics but only 57 unique full
  diagnostic objects.
- Another SystemVerilog file had 20 Slang diagnostics but only 10 unique full
  diagnostic objects.

The repeated entries had equal ranges, messages, severities, codes, sources,
tags, related information, and data.

## Fix

Call `diagClient->clear()` immediately before publishing diagnostics from
`createCompilation(doc, top)`, matching the no-argument overload.

`ServerDiagClient::clear()` retains all old URIs in `m_dirtyUris`. The
subsequent `pushDiags()` therefore republishes rebuilt diagnostics for the new
top-level dependency graph and empty diagnostic arrays for files that are no
longer part of the active compilation.

## Regression test

The added test executes:

```text
setBuildFile("cpu_design.f")
setTopLevel("cpu.sv")
```

It serializes each final `lsp::Diagnostic` with `rfl::json::write()` and rejects
duplicate full objects. This includes range and message while allowing two
diagnostics at the same position when any other LSP attribute differs.

Suggested commands:

```sh
cmake --build build --target server_unittests
ctest --test-dir build \
  -R SetBuildFileThenTopLevelDoesNotDuplicateDiagnostics \
  --output-on-failure
```

Expected result: before the fix, the regression test rejects the second
identical fingerprint; after the fix, every final fingerprint is unique.
