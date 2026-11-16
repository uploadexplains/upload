# Upload

Checkpoints and recovery for AI agents.

An agent saves its state as a JSON checkpoint, optionally encrypted on its own side so the key never leaves it, and gets back a content-addressed id. Upload batches checkpoint hashes into Merkle trees and writes each root to a Log contract on Robinhood Chain. After a crash the agent restores its last good step; at any time anyone can diff two steps or prove a checkpoint existed, unchanged, by a given time.

Website: https://uploadexplains.xyz · Docs: https://uploadexplains.xyz/docs.html · For agents: https://uploadexplains.xyz/llms.txt

This repo holds the open parts: the one-file client [`upload.mjs`](upload.mjs) (MIT, no dependencies, Node 18+, browsers, Deno and Bun), its tests, and the source and tests of the two contracts Upload uses.

## Plug it into your agent

Remote MCP server, no install:

```sh
claude mcp add --transport http upload https://uploadexplains.xyz/api/mcp
```

The same URL works in Cursor, VS Code, Codex, Windsurf and any MCP client. Five tools: `save_checkpoint`, `restore_checkpoint`, `list_checkpoints`, `diff_checkpoints` and `verify_checkpoint`. Every tool is also a plain HTTP route under `https://uploadexplains.xyz/api/`.

## The client

```sh
curl -O https://raw.githubusercontent.com/uploadexplains/upload/main/upload.mjs
node upload.mjs save --agent rebalancer-1 --json '{"step":14}' --label 'before swap'
node upload.mjs restore 0x… --state
node upload.mjs list --head 0x…
node upload.mjs diff 0x… 0x…
node upload.mjs verify 0x…
node upload.mjs help
```

Encrypt on your side:

```sh
node upload.mjs keygen                      # a 32-byte key; keep it, nobody can read the checkpoint without it
node upload.mjs save --agent bot --file state.json --encrypt-key <key>
node upload.mjs restore 0x… --decrypt-key <key> --state
```

As a library:

```js
import { Upload } from './upload.mjs';

const up = new Upload({ key: process.env.UPLOAD_KEY });   // the key is optional: without it, saves are anonymous
const { checkpoint } = await up.save('rebalancer-1', { step: 14 }, { label: 'before swap' });
const { state } = await up.restore(checkpoint);
const report = await up.verify(checkpoint);                // { ok, checks: [...] }, the chain read from your own RPC
```

## The rules

- **id** = sha256 of the checkpoint record's canonical JSON (keys sorted, no whitespace).
- **leaf** = sha256(0x00 ‖ id), so the public batch record never shows an id, which is what restores.
- **node** = sha256(0x01 ‖ left ‖ right). An odd node at the end of a level moves up unchanged.
- **root** = the top node. It is the Log entry's `subject`; the entry's `hash` is sha256 of the batch record.
- **Encryption**: AES-256-GCM, 12-byte IV, AAD `upload/v1/<agent>`. Passphrases go through PBKDF2-SHA256 with 600,000 iterations and a 16-byte salt.

`verify` checks every step on its own: the restored bytes hash to the id, the leaf sits in the batch record, the leaves give the root, the Log entry read from your RPC has that root, and the batch record hashes to the entry's `hash`. The tests include the spec's test vector, the same one the website runs in your browser.

## Free tier and limits

- 200 calls a day per IP without a key, and 300 a day per wallet with an API key. After that, calls spend credits bought with $UPLOAD; buying burns the tokens.
- Free checkpoints: up to 64 KB, kept 7 days, anchored within about 30 minutes. Pro: up to 1 MB, kept 90 days, anchored in the next batch (about every 5 minutes).
- Anyone with a checkpoint id can restore it, like an unlisted link. Ids include a random nonce, so they can't be guessed, but treat them as secrets or encrypt.

## What it can't do

- Prove that your agent computed its state correctly. A checkpoint proves what was saved and when, not that it was right.
- Undo onchain transactions. Restoring state does not reverse anything the agent already sent.
- Keep data forever. Checkpoints expire, and one operator runs the service: keep your own copy of anything you can't lose. The roots onchain stay.

## Contracts

[`contracts/`](contracts) is a Foundry project with both contracts and their tests:

- **Log** (`src/Log.sol`): a public record that can only grow. The operator writes checkpoint roots for free; nothing can edit or delete an entry, not even the owner.
- **Credits** (`src/Credits.sol`): buying credits sends $UPLOAD straight to the dead address. The contract never holds tokens.

```sh
cd contracts
forge install foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
forge test --no-match-contract Fork
forge test --match-contract Fork --fork-url https://rpc.mainnet.chain.robinhood.com   # against a real Pons token
```

The deployed addresses are on the website and in `/llms.txt`, with verified source on the Robinhood Chain explorer.

## Tests

```sh
npm test        # or: node --test test/*.test.mjs
```

Offline, with no dependencies: the test vector, canonical JSON, Merkle proofs, encryption and diff.

## License

MIT. See [LICENSE](LICENSE).
