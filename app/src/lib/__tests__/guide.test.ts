import assert from 'node:assert/strict';
import { test } from 'node:test';

import { currentStep, guideReducer, heard, initialGuide, parseCommand, shortLabel, type GuideAction, type GuideState } from '../guide';

const run = (actions: GuideAction[], from: GuideState = initialGuide) => actions.reduce(guideReducer, from);

const sink: GuideAction[] = [
  { type: 'plan', task: 'Fix the leak under the sink' },
  { type: 'title', text: 'Leaking sink trap' },
  { type: 'step', text: 'Turn off the water under the sink.' },
  { type: 'step', text: 'Put a bucket under the trap.', label: 'P-trap', at: { x: 0.5, y: 0.6 }, mark: 3 },
  { type: 'step', text: 'Loosen the slip nut by hand.', label: 'slip nut.', at: { x: 0.42, y: 0.48 } },
  { type: 'step', text: 'Pull the trap down and empty it.', label: 'trap', at: { x: 0.51, y: 0.61 }, mark: 3 },
  { type: 'planned' },
];

test('a plan collects steps and tags each part once', () => {
  const s = run(sink);
  assert.equal(s.status, 'active');
  assert.equal(s.title, 'Leaking sink trap');
  assert.equal(s.steps.length, 4);
  assert.deepEqual(s.parts.map((p) => p.label), ['P-trap', 'Slip nut']);
  // The third step is on the same mark as the first part, so it reuses its tag.
  assert.equal(s.steps[3].partId, s.steps[1].partId);
  assert.equal(s.steps[0].partId, undefined);
  assert.deepEqual(currentStep(s), { step: s.steps[0], part: null });
});

test('next and back stay in range; next past the end finishes', () => {
  let s = run(sink);
  s = guideReducer(s, { type: 'back' });
  assert.equal(s.index, 0);
  s = run([{ type: 'next' }, { type: 'next' }, { type: 'next' }], s);
  assert.equal(s.index, 3);
  assert.equal(s.status, 'active');
  s = guideReducer(s, { type: 'next' });
  assert.equal(s.status, 'finished');
  assert.equal(s.index, 3);
  assert.equal(guideReducer(s, { type: 'back' }).index, 2);
});

test('a check reports in the panel with a tone, then the guide carries on', () => {
  let s = run([...sink, { type: 'next' }, { type: 'checking' }]);
  assert.equal(s.status, 'checking');
  s = guideReducer(s, { type: 'checked', done: false, text: 'Keep turning anticlockwise.' });
  assert.equal(s.status, 'active');
  assert.deepEqual(s.note, { text: 'Keep turning anticlockwise.', tone: 'warn' });
  assert.equal(guideReducer(s, { type: 'checked', done: null, text: 'Hmm.' }).note?.tone, 'info');
  assert.equal(guideReducer(s, { type: 'next' }).note, null);
});

test('an answer returns to where the guide was, finished included', () => {
  let s = run([...sink, { type: 'go', index: 3 }, { type: 'next' }]);
  assert.equal(s.status, 'finished');
  s = run([{ type: 'answering' }, { type: 'note', note: { text: 'A 1-1/2 inch trap.', tone: 'info' } }], s);
  assert.equal(s.status, 'finished');
  assert.equal(s.note?.text, 'A 1-1/2 inch trap.');
});

test('a question during a check takes over, then the step is live again', () => {
  const s = run([...sink, { type: 'checking' }, { type: 'answering' }, { type: 'note', note: { text: 'Hand tight.', tone: 'info' } }]);
  assert.equal(s.status, 'active');
  assert.equal(s.note?.text, 'Hand tight.');
});

test('with no model, the eyes still tag parts and the guide is usable', () => {
  const s = run([
    { type: 'plan', task: 'Check the tyre pressure' },
    { type: 'part', label: 'wheel', at: { x: 0.8, y: 0.6 } },
    { type: 'part', label: 'car door handle area', at: { x: 0.4, y: 0.5 } },
    { type: 'planned' },
  ]);
  assert.equal(s.status, 'active');
  assert.deepEqual(s.parts.map((p) => p.label), ['Wheel', 'Car door handle']);
  assert.equal(guideReducer(s, { type: 'next' }), s);
});

test('labels are at most three words', () => {
  assert.equal(shortLabel('  the main shut-off valve here. '), 'The main shut-off');
  assert.equal(shortLabel(''), '');
});

test('short phrases are commands; anything else is a question', () => {
  for (const [said, type] of [
    ['next', 'next'],
    ['Okay, next.', 'next'],
    ["I'm done", 'next'],
    ['done', 'next'],
    ['go back', 'back'],
    ['previous step', 'back'],
    ['say that again', 'repeat'],
    ['Repeat.', 'repeat'],
    ['check it', 'check'],
    ['Is this right?', 'check'],
    ['start over', 'stop'],
    ['Next, please.', 'next'],
    ['Um, next step.', 'next'],
    ["What's next?", 'next'],
    ['What\u2019s the next step?', 'next'],
    ['Repeat that.', 'repeat'],
    ['Does this look right?', 'check'],
    ["How's that?", 'check'],
    ['Stop listening.', 'mute'],
    ['Be quiet, please.', 'mute'],
  ] as const) {
    assert.deepEqual(parseCommand(said), { type }, said);
  }
  assert.deepEqual(parseCommand("What's next to the valve?"), { type: 'ask', text: "What's next to the valve?" });
  assert.deepEqual(parseCommand('How tight should the slip nut be?'), { type: 'ask', text: 'How tight should the slip nut be?' });
  assert.equal(parseCommand('   '), null);
});

test('hands free, room talk is let go; commands, questions and "Lensi, …" count', () => {
  // Tapped to talk: everything is for the app.
  assert.deepEqual(heard('the cap is off', false), { type: 'ask', text: 'the cap is off' });
  // Hands free: the same words could be anyone in the room.
  assert.equal(heard('the cap is off', true), null);
  assert.equal(heard('yeah I told him about it yesterday', true), null);
  assert.equal(heard('what', true), null);
  assert.deepEqual(heard('next', true), { type: 'next' });
  assert.deepEqual(heard('Okay, done.', true), { type: 'next' });
  assert.deepEqual(heard('Which tyre is it?', true), { type: 'ask', text: 'Which tyre is it?' });
  assert.deepEqual(heard('how tight does this go', true), { type: 'ask', text: 'how tight does this go' });
  assert.deepEqual(heard("it won't come loose", true), { type: 'ask', text: "it won't come loose" });
  // Said to Lensi by name: always for the app, and the name isn't part of it.
  assert.deepEqual(heard('Lensi, the cap is off', true), { type: 'ask', text: 'the cap is off' });
  assert.deepEqual(heard('Hey Lensi next', true), { type: 'next' });
  assert.equal(heard('Lensi', true), null);
});

test('a part keeps the first shape it gets, thinned for drawing every frame', () => {
  const ring = (n: number) => Array.from({ length: n }, (_, i) => ({ x: 0.5 + 0.1 * Math.cos(i), y: 0.5 + 0.1 * Math.sin(i) }));
  let s = guideReducer({ ...initialGuide, status: 'planning', task: 'x' }, { type: 'step', text: 'Loosen the nut.', label: 'Slip nut', at: { x: 0.5, y: 0.5 }, outline: ring(200) });
  assert.equal(s.parts[0].outline?.length, 48);
  // A later shape doesn't replace it.
  s = guideReducer(s, { type: 'outline', id: s.parts[0].id, outline: ring(5) });
  assert.equal(s.parts[0].outline?.length, 48);
  // A part with none takes one when it arrives; a line is not a shape.
  s = guideReducer(s, { type: 'part', label: 'Trap', at: { x: 0.2, y: 0.8 } });
  assert.equal(s.parts[1].outline, undefined);
  s = guideReducer(s, { type: 'outline', id: s.parts[1].id, outline: ring(2) });
  assert.equal(s.parts[1].outline, undefined);
  s = guideReducer(s, { type: 'outline', id: s.parts[1].id, outline: ring(12) });
  assert.equal(s.parts[1].outline?.length, 12);
});
