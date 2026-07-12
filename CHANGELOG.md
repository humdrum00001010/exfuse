# Changelog

## 0.1.1 - 2026-07-12

- Add the native FSKit backend for macOS and retain the Rust FUSE port for non-macOS systems.
- Add Mix tasks for FSKit checking, provisioning, signing, bundling, and installation.
- Add protocol v2 request IDs, bounded concurrent reads, and ordered stateful operations.
- Improve mount ownership, teardown, duplicate-server prevention, and legacy FSKit resource cleanup.
- Fix FSKit item identity, per-volume wire sessions, content timestamps, directory reads, and generic URL mounts.

## 0.1.0

- Initial `exfuse` package prepared for Hex.
- Mounts Elixir-defined filesystem trees through a Rust FUSE port.
- Supports route macros, plugged endpoint processes, long-lived sockets, caller context, file handles, and mounted traversal with `find`.
- Licensed under MIT.
