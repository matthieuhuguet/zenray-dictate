import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(
  new URL('../Sources/ZenRayDictate/Resources/bridge.js', import.meta.url),
  'utf8'
);
const context = { window: { __zrTestMode: true } };
vm.runInNewContext(source, context);

const { resolveClipboardText, cutComposer } = context.window.__zrClipboardTest;

test('dictation copies existing and newly dictated text', () => {
  assert.equal(
    resolveClipboardText('Texte 1', 'Texte 2', 'Texte 1 Texte 2'),
    'Texte 1 Texte 2'
  );
});

test('dictation keeps existing text when the DOM update is late', () => {
  assert.equal(
    resolveClipboardText('Texte 1', 'Texte 2', 'Texte 1'),
    'Texte 1 Texte 2'
  );
});

test('Ctrl+X returns the whole composer and clears it', () => {
  let cleared = false;
  const text = cutComposer(() => 'Texte 1 Texte 2', () => { cleared = true; });
  assert.equal(text, 'Texte 1 Texte 2');
  assert.equal(cleared, true);
});
