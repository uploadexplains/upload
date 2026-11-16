#!/usr/bin/env node
// upload.mjs: a one-file client for Upload (https://uploadexplains.xyz), checkpoints for AI agents.
// Save, restore, list, diff and verify checkpoints; encrypt state on your side with AES-256-GCM so the key never
// leaves your machine; verify a checkpoint against the Merkle root onchain by reading the chain from your own RPC.
// Node 18+ (or any modern browser, Deno or Bun). No dependencies.
//
//   import { Upload, generateKey } from './upload.mjs';
//   const up = new Upload({ key: process.env.UPLOAD_KEY });          // key optional: without it, saves are anonymous
//   const { checkpoint } = await up.save('rebalancer-1', { step: 14 }, { label: 'before swap' });
//   const { state } = await up.restore(checkpoint);
//   const report = await up.verify(checkpoint);                       // { ok, checks: [...] }
//
//   node upload.mjs help
//
// MIT License. Copyright (c) 2026 Upload. Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software, to deal in it without restriction, including the rights to use, copy, modify, merge, publish,
// distribute, sublicense and sell copies, provided this notice is included. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT
// WARRANTY OF ANY KIND.

export const VERSION = '1.0.0';
export const DEFAULT_BASE = 'https://uploadexplains.xyz';
export const DEFAULT_RPC = 'https://rpc.mainnet.chain.robinhood.com';
const ENTRY_SELECTOR = '0xe2095c07'; // entry(uint256) on the Log contract
const KIND_ROOT = 1;
const PBKDF2_ITERATIONS = 600_000;
const subtle = globalThis.crypto?.subtle;
const enc = new TextEncoder();
const dec = new TextDecoder();

// ------------------------------------------------------------------ encoding and hashing (the same rules as the server)

/** Canonical JSON: keys sorted, no whitespace, JSON.stringify for strings and numbers. */
export function canon(v) {
  if (v === null || typeof v === 'boolean' || typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) throw new Error('numbers must be finite');
    return JSON.stringify(v);
  }
  if (Array.isArray(v)) return '[' + v.map((x) => (x === undefined ? 'null' : canon(x))).join(',') + ']';
  if (typeof v === 'object') {
    return '{' + Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}';
  }
  throw new Error('state must be JSON');
}

export const toHex = (b) => '0x' + [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
export function fromHex(h) {
  const s = h.startsWith('0x') ? h.slice(2) : h;
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  return out;
}
export function b64u(bytes) {
  let s = '';
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export function fromB64u(s) {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}
const cat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};

export async function sha256(bytes) {
  return new Uint8Array(await subtle.digest('SHA-256', typeof bytes === 'string' ? enc.encode(bytes) : bytes));
}
/** A checkpoint id: sha256 of the record's exact bytes. */
export const idOf = async (bytes) => toHex(await sha256(bytes));
/** Merkle leaf: sha256(0x00 || id). */
export const leafOf = async (id) => toHex(await sha256(cat(Uint8Array.of(0), fromHex(id))));
/** Merkle node: sha256(0x01 || left || right). */
export const nodeOf = async (l, r) => toHex(await sha256(cat(Uint8Array.of(1), fromHex(l), fromHex(r))));
/** Walks a leaf up its path ([{ side: 'left' | 'right', hash }], side = the sibling's side) to the root. */
export async function rootFrom(leaf, path) {
  let h = leaf;
  for (const s of path) h = s.side === 'left' ? await nodeOf(s.hash, h) : await nodeOf(h, s.hash);
  return h;
}
/** The root of a list of leaves; an odd node at the end of a level moves up unchanged. */
export async function merkleRoot(leaves) {
  let lvl = leaves.slice();
  if (!lvl.length) return null;
  while (lvl.length > 1) {
    const next = [];
    for (let i = 0; i < lvl.length; i += 2) next.push(i + 1 < lvl.length ? await nodeOf(lvl[i], lvl[i + 1]) : lvl[i]);
    lvl = next;
  }
  return lvl[0];
}

// ------------------------------------------------------------------ encryption (AES-256-GCM, on your side)

/** A new random 32-byte key, base64url. Keep it safe: nobody can read your checkpoints without it, including you. */
export function generateKey() {
  return b64u(globalThis.crypto.getRandomValues(new Uint8Array(32)));
}

async function aesKey(secret, kdf) {
  if (kdf) {
    const base = await subtle.importKey('raw', enc.encode(secret), 'PBKDF2', false, ['deriveKey']);
    return subtle.deriveKey({ name: 'PBKDF2', hash: 'SHA-256', salt: fromB64u(kdf.salt), iterations: kdf.iterations }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  }
  const raw = fromB64u(secret);
  if (raw.length !== 32) throw new Error('An encryption key is 32 bytes in base64url (node upload.mjs keygen makes one).');
  return subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

/**
 * Encrypts state for save(): { alg, iv, ciphertext, aad, kdf }. Pass { key } (base64url, from generateKey) or
 * { passphrase } (PBKDF2-SHA256, 600,000 iterations, random salt). The AAD binds the ciphertext to the agent name.
 */
export async function encryptState(state, { key, passphrase, agent = 'default' } = {}) {
  const kdf = passphrase ? { name: 'PBKDF2-SHA256', salt: b64u(globalThis.crypto.getRandomValues(new Uint8Array(16))), iterations: PBKDF2_ITERATIONS } : null;
  const k = await aesKey(passphrase || key, kdf);
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(12));
  const aad = `upload/v1/${agent}`;
  const ct = await subtle.encrypt({ name: 'AES-GCM', iv, additionalData: enc.encode(aad) }, k, enc.encode(canon(state)));
  return { alg: 'AES-256-GCM', iv: b64u(iv), ciphertext: b64u(ct), aad, ...(kdf ? { kdf } : {}) };
}

/** Decrypts a restored record's state with the key or passphrase it was saved with. */
export async function decryptRecord(record, { key, passphrase } = {}) {
  if (record.encoding !== 'aes-256-gcm') return record.state;
  const e = record.enc || {};
  if (e.kdf && !passphrase) throw new Error('This checkpoint was encrypted with a passphrase: pass { passphrase }.');
  if (!e.kdf && !key) throw new Error('This checkpoint is encrypted: pass { key }.');
  const k = await aesKey(e.kdf ? passphrase : key, e.kdf);
  let pt;
  try {
    pt = await subtle.decrypt({ name: 'AES-GCM', iv: fromB64u(e.iv), ...(e.aad ? { additionalData: enc.encode(e.aad) } : {}) }, k, fromB64u(record.state));
  } catch {
    throw new Error('Could not decrypt: wrong key or passphrase, or the ciphertext was changed.');
  }
  return JSON.parse(dec.decode(pt));
}

// ------------------------------------------------------------------ diff (the same output as the server's)

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const ptr = (path, k) => `${path}/${String(k).replace(/~/g, '~0').replace(/\//g, '~1')}`;
/** Changes from a to b: [{ op: 'add' | 'remove' | 'change', path (JSON Pointer), from?, to? }]. */
export function diffJson(a, b, path = '', out = [], max = 500) {
  if (out.length >= max) return out;
  if (isObj(a) && isObj(b)) {
    for (const k of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()) {
      if (out.length >= max) break;
      if (!(k in b)) out.push({ op: 'remove', path: ptr(path, k), from: a[k] });
      else if (!(k in a)) out.push({ op: 'add', path: ptr(path, k), to: b[k] });
      else diffJson(a[k], b[k], ptr(path, k), out, max);
    }
  } else if (Array.isArray(a) && Array.isArray(b)) {
    for (let i = 0; i < Math.max(a.length, b.length) && out.length < max; i++) {
      if (i >= b.length) out.push({ op: 'remove', path: ptr(path, i), from: a[i] });
      else if (i >= a.length) out.push({ op: 'add', path: ptr(path, i), to: b[i] });
      else diffJson(a[i], b[i], ptr(path, i), out, max);
    }
  } else if (canon(a) !== canon(b)) {
    out.push({ op: 'change', path, from: a, to: b });
  }
  return out;
}

// ------------------------------------------------------------------ reading the Log entry from your own RPC

/** Reads entry(id) from a Log contract: { author, time, kind, ref, subject, hash, uri }. */
export async function readLogEntry(contract, id, { rpc = DEFAULT_RPC, fetch: f = globalThis.fetch } = {}) {
  const data = ENTRY_SELECTOR + BigInt(id).toString(16).padStart(64, '0');
  let res;
  for (let i = 0; i < 4; i++) {
    res = await f(rpc, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to: contract, data }, 'latest'] }) });
    if (res.status !== 429) break;
    await new Promise((r) => setTimeout(r, 500 * 2 ** i)); // the public RPC rate-limits bursts
  }
  const j = await res.json();
  if (j.error || !j.result || j.result === '0x') throw new Error(`The chain did not return the entry: ${j.error?.message || 'empty result'}`);
  const w = (n) => j.result.slice(2 + n * 64, 2 + (n + 1) * 64);
  const t = parseInt(w(0), 16) / 32; // the tuple starts at the first word's offset
  const word = (n) => w(t + n);
  const uriAt = t + parseInt(word(6), 16) / 32;
  const len = parseInt(w(uriAt), 16);
  const uri = dec.decode(fromHex(j.result.slice(2 + (uriAt + 1) * 64, 2 + (uriAt + 1) * 64 + len * 2)));
  return {
    author: '0x' + word(0).slice(24), time: parseInt(word(1), 16), kind: parseInt(word(2), 16), ref: BigInt('0x' + word(3)).toString(),
    subject: '0x' + word(4), hash: '0x' + word(5), uri,
  };
}

// ------------------------------------------------------------------ the client

export class UploadError extends Error {
  constructor(status, body) {
    super(`${body?.error || 'error'} (${status}): ${body?.message || ''}`.trim());
    this.status = status;
    this.body = body;
  }
}

export class Upload {
  /**
   * { base = https://uploadexplains.xyz, key (ck_…, optional), rpc (for verify), site (adds ?id=<site>, only for
   * previews on a shared host such as a local dev server), fetch }
   */
  constructor({ base = DEFAULT_BASE, key = null, rpc = DEFAULT_RPC, site = null, fetch: f = globalThis.fetch } = {}) {
    this.base = base.replace(/\/+$/, '');
    this.site = site;
    this.key = key;
    this.rpc = rpc;
    this.fetch = f;
  }

  async request(path, { method = 'GET', body, query, raw = false } = {}) {
    const params = new URLSearchParams(Object.entries(query || {}).filter(([, v]) => v !== undefined && v !== null));
    if (this.site) params.set('id', this.site);
    const q = params.size ? `?${params}` : '';
    const headers = { 'user-agent': `upload.mjs/${VERSION}` };
    if (body !== undefined) headers['content-type'] = 'application/json';
    if (this.key) headers.authorization = `Bearer ${this.key}`;
    const res = await this.fetch(`${this.base}/api/${path}${q}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    if (raw && res.ok) return new Uint8Array(await res.arrayBuffer());
    let data = null;
    try { data = await res.json(); } catch {}
    if (!res.ok) throw new UploadError(res.status, data);
    return data;
  }

  /** Saves state. opts: { parent, label, pro, key | passphrase (to encrypt on this side) }. */
  async save(agent, state, { parent, label, pro, key, passphrase } = {}) {
    const body = { agent, parent, label, pro: pro || undefined };
    if (key || passphrase) body.encrypted = await encryptState(state, { key, passphrase, agent });
    else body.state = state;
    return this.request('save', { method: 'POST', body });
  }

  /** The exact stored bytes of a checkpoint. */
  raw(id) {
    return this.request('restore', { query: { ckpt: id, raw: 1 }, raw: true });
  }

  /** { record, state, anchor }. Checks the bytes hash to the id, and decrypts with { key } or { passphrase }. */
  async restore(id, { key, passphrase } = {}) {
    const bytes = await this.raw(id);
    if ((await idOf(bytes)) !== id.toLowerCase()) throw new Error('The restored bytes do not hash to this id.');
    const record = JSON.parse(dec.decode(bytes));
    const state = await decryptRecord(record, { key, passphrase });
    return { checkpoint: id, record, state };
  }

  /** { agent } (with an API key), or { head } to walk back through parents. No arguments: your agent names. */
  list({ agent, head, limit } = {}) {
    return this.request('checkpoints', { query: { agent, head, limit } });
  }

  /** What changed from a to b. Encrypted checkpoints are decrypted and compared here, never on the server. */
  async diff(a, b, opts = {}) {
    if (!opts.key && !opts.passphrase) {
      try { return await this.request('diff', { query: { a, b } }); } catch (e) { if (e.body?.error !== 'encrypted') throw e; }
    }
    const [x, y] = await Promise.all([this.restore(a, opts), this.restore(b, opts)]);
    const changes = diffJson(x.state, y.state);
    return { a, b, same: changes.length === 0, local: true, changes };
  }

  /**
   * Verifies a checkpoint on this side: its bytes hash to its id, its leaf is in the batch, the Merkle path gives the
   * root, the batch record hashes to the Log entry's hash, and the Log entry (read from your RPC) has the root as its
   * subject. Returns { ok, anchored, checks: [{ check, ok, detail }], anchor }.
   */
  async verify(id) {
    const checks = [];
    const add = (check, ok, detail) => checks.push({ check, ok: Boolean(ok), detail });
    const bytes = await this.raw(id);
    add('stored', (await idOf(bytes)) === id.toLowerCase(), 'sha256 of the restored bytes equals the id');
    const v = await this.request('verify', { query: { ckpt: id } });
    if (!v.anchored) return { ok: false, anchored: false, checks, anchor: v.anchor };
    const leaf = await leafOf(id.toLowerCase());
    const { anchor, proof } = v;
    add('proof', (await rootFrom(leaf, proof.path)) === anchor.root, 'the leaf hashed up its path gives the root');
    let batchBytes = null;
    try {
      const u = new URL(anchor.batch);
      if (this.site && !u.searchParams.has('id')) u.searchParams.set('id', this.site);
      const r = await this.fetch(u.toString());
      if (r.ok) batchBytes = new Uint8Array(await r.arrayBuffer());
    } catch {}
    const batch = batchBytes ? JSON.parse(dec.decode(batchBytes)) : null;
    add('leaf', batch?.leaves?.[anchor.index] === leaf, `leaf ${anchor.index} of the batch record is sha256(0x00 || id)`);
    add('batch-root', batch && (await merkleRoot(batch.leaves)) === anchor.root, 'the batch record\'s leaves give the same root');
    const e = await readLogEntry(anchor.contract, anchor.entry, { rpc: this.rpc, fetch: this.fetch });
    add('onchain', e.subject.toLowerCase() === anchor.root && e.kind === KIND_ROOT, `Log entry #${anchor.entry} (read from ${this.rpc}) has the root as its subject`);
    add('batch', batchBytes && toHex(await sha256(batchBytes)) === e.hash.toLowerCase(), 'sha256 of the batch record equals the entry\'s hash');
    return { ok: checks.every((c) => c.ok), anchored: true, checks, anchor: { ...anchor, time: new Date(e.time * 1000).toISOString(), author: e.author } };
  }

  stats() { return this.request('stats'); }
}

// ------------------------------------------------------------------ MCP (a tiny client, for checks)

export async function mcp(url, method, params, { key, id = 1, note = false, fetch: f = globalThis.fetch } = {}) {
  const headers = { 'content-type': 'application/json', accept: 'application/json, text/event-stream' };
  if (key) headers.authorization = `Bearer ${key}`;
  const msg = note ? { jsonrpc: '2.0', method } : { jsonrpc: '2.0', id, method, ...(params ? { params } : {}) };
  const res = await f(url, { method: 'POST', headers, body: JSON.stringify(msg) });
  if (res.status === 202) return null;
  const j = await res.json();
  if (j.error) throw new Error(`MCP ${method}: ${j.error.message || j.error}`);
  return j.result;
}

// ------------------------------------------------------------------ command line

const HELP = `upload.mjs ${VERSION}: checkpoints for AI agents (https://uploadexplains.xyz)

  node upload.mjs keygen
  node upload.mjs save --agent <name> (--file state.json | --json '{"step":1}') [--label <text>] [--parent <id|none>] [--pro]
                       [--encrypt-key <key> | --passphrase <text>]
  node upload.mjs restore <id> [--decrypt-key <key> | --passphrase <text>] [--state]
  node upload.mjs list [--agent <name>] [--head <id>] [--limit <n>]
  node upload.mjs diff <a> <b> [--decrypt-key <key> | --passphrase <text>]
  node upload.mjs verify <id> [--rpc <url>]
  node upload.mjs stats
  node upload.mjs mcp-check

Environment: UPLOAD_KEY (an API key, ck_…), UPLOAD_BASE (default ${DEFAULT_BASE}), UPLOAD_RPC (default ${DEFAULT_RPC}),
UPLOAD_SITE (only for previews on a shared host: adds ?id=<site>).
A passphrase on the command line can end up in your shell history; prefer --encrypt-key with a key from keygen.`;

async function cli(argv) {
  const [cmd, ...rest] = argv;
  const flags = {};
  const pos = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (['pro', 'state'].includes(k)) flags[k] = true;
      else flags[k] = rest[++i];
    } else pos.push(a);
  }
  const env = globalThis.process?.env || {};
  const up = new Upload({
    base: flags.base || env.UPLOAD_BASE || DEFAULT_BASE, key: flags.key || env.UPLOAD_KEY || null,
    rpc: flags.rpc || env.UPLOAD_RPC || DEFAULT_RPC, site: flags.site || env.UPLOAD_SITE || null,
  });
  const out = (x) => console.log(typeof x === 'string' ? x : JSON.stringify(x, null, 2));
  const secret = { key: flags['decrypt-key'] || flags['encrypt-key'], passphrase: flags.passphrase };
  switch (cmd) {
    case 'keygen': return out(generateKey());
    case 'save': {
      const { readFile } = await import('node:fs/promises');
      const text = flags.file ? await readFile(flags.file, 'utf8') : flags.json;
      if (text === undefined) throw new Error('Pass --file state.json or --json \'{...}\'.');
      return out(await up.save(flags.agent || 'default', JSON.parse(text), { parent: flags.parent, label: flags.label, pro: flags.pro, ...secret }));
    }
    case 'restore': {
      const r = await up.restore(pos[0], secret);
      return out(flags.state ? r.state : r);
    }
    case 'list': return out(await up.list({ agent: flags.agent, head: flags.head, limit: flags.limit }));
    case 'diff': return out(await up.diff(pos[0], pos[1], secret.key || secret.passphrase ? secret : {}));
    case 'verify': {
      const r = await up.verify(pos[0]);
      out(r);
      if (globalThis.process && !r.ok) process.exitCode = 1;
      return;
    }
    case 'stats': return out(await up.stats());
    case 'mcp-check': {
      const url = `${up.base}/api/mcp${up.site ? `?id=${up.site}` : ''}`;
      const init = await mcp(url, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'upload.mjs', version: VERSION } }, { key: up.key });
      await mcp(url, 'notifications/initialized', undefined, { key: up.key, note: true });
      const { tools } = await mcp(url, 'tools/list', {}, { key: up.key, id: 2 });
      await mcp(url, 'ping', {}, { key: up.key, id: 3 });
      return out({ server: init.serverInfo, protocolVersion: init.protocolVersion, tools: tools.map((t) => t.name) });
    }
    default: return out(HELP);
  }
}

const isMain = typeof process !== 'undefined' && process.argv?.[1] && import.meta.url === (await import('node:url')).pathToFileURL(process.argv[1]).href;
if (isMain) {
  cli(process.argv.slice(2)).catch((e) => {
    console.error(e.message || e);
    process.exitCode = 1;
  });
}
