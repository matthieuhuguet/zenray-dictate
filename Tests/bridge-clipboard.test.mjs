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

const {
  resolveClipboardText,
  cutComposer,
  themeName,
  isSendButton,
  isDictationStopButton,
  isIntensityButton
} = context.window.__zrClipboardTest;

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

test('Cmd+X returns the whole composer and clears it', () => {
  let cleared = false;
  const text = cutComposer(() => 'Texte 1 Texte 2', () => { cleared = true; });
  assert.equal(text, 'Texte 1 Texte 2');
  assert.equal(cleared, true);
});

test('the compact bar follows the macOS light or dark preference', () => {
  assert.equal(themeName(false), 'light');
  assert.equal(themeName(true), 'dark');
});

test('only prompt send buttons are removed', () => {
  assert.equal(isSendButton('Send prompt', null), true);
  assert.equal(isSendButton('Send dictated message', null), true);
  assert.equal(isSendButton('Send', null), true);
  assert.equal(isSendButton(null, 'send-button'), true);
  assert.equal(isSendButton(null, 'composer-submit-button'), true);
  assert.equal(isSendButton('Stop dictation', null), false);
  assert.equal(isSendButton('Submit dictation', null), false);
  assert.equal(isDictationStopButton('Stop dictation'), true);
  assert.equal(isDictationStopButton('Submit dictation'), true);
  assert.equal(isDictationStopButton('Send dictated message'), false);
});

test('the compact intensity selector is removed at every level', () => {
  assert.equal(isIntensityButton('Low'), true);
  assert.equal(isIntensityButton('Medium'), true);
  assert.equal(isIntensityButton('High'), true);
  assert.equal(isIntensityButton('Extra High'), true);
  assert.equal(isIntensityButton('Start dictation'), false);
});
