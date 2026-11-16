# Changelog

## 1.0.0 (17 November 2026)

- `upload.mjs`: save, restore, list, diff and verify checkpoints from the command line or as a library. Node 18+, browsers, Deno and Bun, no dependencies.
- Client-side encryption with AES-256-GCM, from a key (`keygen`) or a passphrase (PBKDF2-SHA256, 600,000 iterations).
- `verify` checks a checkpoint against its Merkle root in the Log contract, read from your own RPC.
- Remote MCP server at https://uploadexplains.xyz/api/mcp with five tools.
- The Log and Credits contracts with their Foundry tests.
