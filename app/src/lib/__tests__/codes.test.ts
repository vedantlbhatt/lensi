import assert from 'node:assert/strict';
import { test } from 'node:test';

import { codeLabel, readCode } from '../codes';

test('plain links', () => {
  assert.deepEqual(readCode('https://www.example.com/setup?x=1'), { kind: 'url', url: 'https://www.example.com/setup?x=1', host: 'example.com' });
  assert.equal(codeLabel('https://www.example.com/setup'), 'Link · example.com');
});

test('MEBKM bookmarks with escaped colons (the zxing sample Lensi read in CI)', () => {
  assert.deepEqual(readCode(String.raw`MEBKM:URL:http\://en.wikipedia.org/wiki/Main_Page;;`), {
    kind: 'url',
    url: 'http://en.wikipedia.org/wiki/Main_Page',
    host: 'en.wikipedia.org',
  });
});

test('Wi-Fi codes give the network and its password', () => {
  assert.deepEqual(readCode(String.raw`WIFI:T:WPA;S:Home\;Net;P:pa\:ss;;`), { kind: 'wifi', ssid: 'Home;Net', password: 'pa:ss' });
  assert.deepEqual(readCode('WIFI:S:Cafe;T:nopass;;'), { kind: 'wifi', ssid: 'Cafe', password: null });
  assert.equal(codeLabel('WIFI:S:Cafe;T:nopass;;'), 'Wi-Fi · Cafe');
});

test('anything else is text', () => {
  assert.deepEqual(readCode('  4006381333931 '), { kind: 'text', text: '4006381333931' });
});
