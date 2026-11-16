// Offline tests for upload.mjs: canonical JSON, ids, the Merkle tree, encryption and diff.
// Run: npm test   (Node 18+, no dependencies, no network)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canon, idOf, leafOf, nodeOf, merkleRoot, rootFrom, generateKey, encryptState, decryptRecord, diffJson,
} from '../upload.mjs';

const enc = new TextEncoder();

// The spec's test vector: the same values the website computes in your browser and the server's code produces.
const VECTOR = {
  record: {
    v: 1, type: 'upload.checkpoint', agent: 'rebalancer-1', owner: null, label: 'before swap',
    savedAt: '2026-11-16T09:00:00.000Z', retention: 'free', expires: '2026-11-23T09:00:00.000Z',
    nonce: '00112233445566778899aabbccddeeff', encoding: 'json', enc: null,
    state: { step: 14, todo: ['quote', 'swap'], cash: 120.5 }, parent: null, seq: 1,
  },
  others: ['0x' + '11'.repeat(32), '0x' + '22'.repeat(32)],
};
const EXPECT = {
  stateText: '{"cash":120.5,"step":14,"todo":["quote","swap"]}',
  stateHash: '0x010f28e9a7a1b82715a31685e72f66796911a97b17905eaaa2b3fbdd4c4f379c',
  id: '0x580d14bf2ad2cd18018b73360de22b44b72c2c624176de291346ea84773eef01',
  leaf: '0xfda1a574aa7ced04622e4092d92d1b2bd836dc0e116a38d2806e04fd38bbbc35',
  root: '0x1e48547fee1647fc0b7238d42a6cd22da9ffaa5545f25d7728ec26abfccac1dc',
};

test('the test vector gives the published stateHash, id, leaf and root', async () => {
  const stateText = canon(VECTOR.record.state);
  assert.equal(stateText, EXPECT.stateText);
  const stateHash = await idOf(enc.encode(stateText));
  assert.equal(stateHash, EXPECT.stateHash);
  const record = { ...VECTOR.record, stateHash, size: enc.encode(stateText).length };
  const id = await idOf(enc.encode(canon(record)));
  assert.equal(id, EXPECT.id);
  const leaf = await leafOf(id);
  assert.equal(leaf, EXPECT.leaf);
  const leaves = [leaf, ...(await Promise.all(VECTOR.others.map(leafOf)))];
  assert.equal(await merkleRoot(leaves), EXPECT.root);
});

test('canonical JSON sorts keys at every level and drops whitespace', () => {
  assert.equal(canon({ b: 1, a: { d: [2, { z: 0, y: 'x' }], c: null } }), '{"a":{"c":null,"d":[2,{"y":"x","z":0}]},"b":1}');
  assert.equal(canon([undefined, true]), '[null,true]');
  assert.throws(() => canon({ n: Infinity }), /finite/);
});

test('an odd node moves up unchanged, and every leaf proves up to the root', async () => {
  const leaves = await Promise.all(['0x' + 'aa'.repeat(32), '0x' + 'bb'.repeat(32), '0x' + 'cc'.repeat(32)].map(leafOf));
  const root = await merkleRoot(leaves);
  assert.equal(root, await nodeOf(await nodeOf(leaves[0], leaves[1]), leaves[2]));
  assert.equal(await merkleRoot([leaves[0]]), leaves[0]);
  assert.equal(await merkleRoot([]), null);
  // Paths as the server returns them: each step names the sibling and which side it sits on.
  const ab = await nodeOf(leaves[0], leaves[1]);
  assert.equal(await rootFrom(leaves[0], [{ side: 'right', hash: leaves[1] }, { side: 'right', hash: leaves[2] }]), root);
  assert.equal(await rootFrom(leaves[1], [{ side: 'left', hash: leaves[0] }, { side: 'right', hash: leaves[2] }]), root);
  assert.equal(await rootFrom(leaves[2], [{ side: 'left', hash: ab }]), root);
  assert.notEqual(await rootFrom(leaves[2], [{ side: 'right', hash: ab }]), root);
});

test('a leaf is sha256(0x00 || id), so the public batch never shows the id', async () => {
  const id = EXPECT.id;
  assert.notEqual(await leafOf(id), id);
  assert.notEqual(await leafOf(id), await idOf(Uint8Array.from(Buffer.from(id.slice(2), 'hex'))));
});

test('a key encrypts and decrypts; a wrong key or another agent name fails', async () => {
  const key = generateKey();
  const state = { step: 3, secret: 'only for me' };
  const e = await encryptState(state, { key, agent: 'bot-1' });
  assert.equal(e.alg, 'AES-256-GCM');
  assert.equal(e.aad, 'upload/v1/bot-1');
  const record = { encoding: 'aes-256-gcm', state: e.ciphertext, enc: { iv: e.iv, aad: e.aad } };
  assert.deepEqual(await decryptRecord(record, { key }), state);
  await assert.rejects(decryptRecord(record, { key: generateKey() }), /Could not decrypt/);
  await assert.rejects(decryptRecord({ ...record, enc: { ...record.enc, aad: 'upload/v1/bot-2' } }, { key }), /Could not decrypt/);
  await assert.rejects(decryptRecord(record, {}), /pass \{ key \}/);
});

test('a passphrase goes through PBKDF2 and decrypts only with the same passphrase', async () => {
  const e = await encryptState({ ok: true }, { passphrase: 'correct horse', agent: 'bot-1' });
  assert.equal(e.kdf.iterations, 600000);
  const record = { encoding: 'aes-256-gcm', state: e.ciphertext, enc: { iv: e.iv, aad: e.aad, kdf: e.kdf } };
  assert.deepEqual(await decryptRecord(record, { passphrase: 'correct horse' }), { ok: true });
  await assert.rejects(decryptRecord(record, { passphrase: 'wrong' }), /Could not decrypt/);
});

test('plain JSON records come back as they are', async () => {
  assert.deepEqual(await decryptRecord({ encoding: 'json', state: { a: 1 } }), { a: 1 });
});

test('diff lists adds, removes and changes as JSON Pointers', () => {
  const a = { step: 1, cash: 100, notes: ['start'], meta: { 'a/b': 1, gone: true } };
  const b = { step: 2, cash: 100, notes: ['start', 'swap'], meta: { 'a/b': 2 } };
  assert.deepEqual(diffJson(a, b), [
    { op: 'change', path: '/meta/a~1b', from: 1, to: 2 },
    { op: 'remove', path: '/meta/gone', from: true },
    { op: 'add', path: '/notes/1', to: 'swap' },
    { op: 'change', path: '/step', from: 1, to: 2 },
  ]);
  assert.deepEqual(diffJson({ x: 1 }, { x: 1 }), []);
  assert.equal(diffJson({}, Object.fromEntries([...Array(20)].map((_, i) => [`k${i}`, i])), '', [], 5).length, 5);
});
