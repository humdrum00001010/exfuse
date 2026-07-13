# Changelog

## Unreleased

- Let Xcode own FSKit host and extension provisioning and signing.
- Remove runtime signing/profile modules and the generated provisioning project.
- Fix FSKit item identity across rename-over-existing: `getattr`/`setattr`/`readdir` now report the pinned item ID instead of recomputing it from the current path, so a temp file renamed over an existing name keeps one consistent object identity.
- Add wire client socket timeouts so a backend that accepts but never replies (protocol skew, wedged listener) fails bounded with ETIMEDOUT instead of blocking extension threads forever.
- Reuse a fixed pool of wire connections per volume instead of dialing one ephemeral localhost connection per filesystem callback.
- Reply framed ENOSYS/EIO errors to unsupported or unrecognizable wire packets on the TCP transport instead of leaving the client waiting on a reply that never comes.

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
