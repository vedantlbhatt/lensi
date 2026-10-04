import assert from 'node:assert/strict';
import { test } from 'node:test';

import { isHowTo } from '../questions';

test('how-to questions become walkthroughs', () => {
  for (const q of [
    'How do I descale this?',
    'How should I pack this so nothing tips over?',
    'What is the cleanest way to peel this?',
    "What's the best way to clean it?",
    'Walk me through it',
    'Show me how to replace the filter',
  ]) {
    assert.equal(isHowTo(q), true, q);
  }
});

test('everything else gets an answer', () => {
  for (const q of ['What is it for?', 'How many people are there?', 'What does the sign say?', 'Is this safe for kids?', 'Which way is north?', 'Is this the right way up?']) {
    assert.equal(isHowTo(q), false, q);
  }
});
