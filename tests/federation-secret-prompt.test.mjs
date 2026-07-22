import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import test from 'node:test';
import { readSecret } from '../lib/federation-secret-prompt.mjs';

test('TTY secret entry uses raw mode and never echoes the pasted authtoken', async () => {
  const input = new EventEmitter();
  input.isTTY = true;
  input.isRaw = false;
  input.resume = () => {};
  const rawModes = [];
  input.setRawMode = (enabled) => rawModes.push(enabled);
  let output = '';
  const value = readSecret({ input, output: { write: (text) => { output += text; } }, prompt: 'Paste your authtoken (Your Authtoken page): ' });
  input.emit('data', Buffer.from('super-secret-token\r'));
  assert.equal(await value, 'super-secret-token');
  assert.deepEqual(rawModes, [true, false]);
  assert.equal(output, 'Paste your authtoken (Your Authtoken page): \n');
  assert.doesNotMatch(output, /super-secret-token/);
});

test('piped secret entry reads a plain line without terminal echo handling', async () => {
  const input = Readable.from(['piped-token\n']);
  input.isTTY = false;
  let output = '';
  const value = await readSecret({ input, output: { write: (text) => { output += text; } }, prompt: 'Paste your authtoken (Your Authtoken page): ' });
  assert.equal(value, 'piped-token');
  assert.equal(output, 'Paste your authtoken (Your Authtoken page): ');
});
