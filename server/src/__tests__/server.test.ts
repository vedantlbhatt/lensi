import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { after, before, test } from "node:test";

process.env.LENSI_MOCK = "1";
const { createServer } = await import("../server.js");
// The app's own parser, so this test proves the two sides agree.
const { LineSplitter, parseLine } = await import("../../../app/src/lib/protocol.ts");
const { userText } = await import("../prompt.js");

let base = "";
const server = createServer();
before(async () => {
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
after(() => server.close());

async function stream(body: object) {
  const res = await fetch(`${base}/annotate`, { method: "POST", body: JSON.stringify(body) });
  assert.equal(res.status, 200);
  const text = await res.text();
  const split = new LineSplitter();
  return [...split.push(text), ...split.flush()].map(parseLine).filter(Boolean);
}

test("health reports the mock provider", async () => {
  const res = await fetch(`${base}/health`);
  assert.deepEqual(await res.json(), { ok: true, provider: "mock", model: "mock" });
});

test("annotate streams every annotation line kind", async () => {
  const events = await stream({ image: "x", lens: "identify", marks: "1: subject (toaster), center\n2: text \"PUSH\", top right" });
  const kinds = events.map((e) => e!.kind);
  assert.deepEqual(kinds, ["title", "summary", "callout", "callout", "fact", "fact"]);
  assert.deepEqual(events[3], { kind: "callout", label: "marked part", mark: 1 });
});

test("walkthrough streams steps with points, marks and plain text", async () => {
  const events = await stream({ image: "x", walkthrough: true, question: "How do I clean it?", marks: "4: text \"OPEN\", top left" });
  assert.equal(events[0]!.kind, "title");
  const steps = events.filter((e) => e!.kind === "step");
  assert.equal(steps.length, 4);
  assert.deepEqual(steps[1], { kind: "step", text: "Press the release on the marked part.", mark: 4 });
  assert.deepEqual(steps[3], { kind: "step", text: "Rinse, dry and slide it back until it clicks." });
});

test("questions stream answers and an optional pointer", async () => {
  const events = await stream({ image: "x", question: "What is it?" });
  assert.deepEqual(events.map((e) => e!.kind), ["answer", "answer", "callout"]);
});

test("bad requests are rejected", async () => {
  assert.equal((await fetch(`${base}/annotate`, { method: "POST", body: "{}" })).status, 400);
  assert.equal((await fetch(`${base}/nope`)).status, 404);
});

test("user text carries hint, marks, history and the task", () => {
  const t = userText({
    image: "x",
    label: "kettle",
    lens: "fix",
    marks: "1: subject (kettle), center",
    question: "Why won't it boil?",
    history: [{ question: "What is it?", answer: "A kettle." }],
  });
  assert.match(t, /quick guess for the main thing: "kettle"/);
  assert.match(t, /Marks the phone found:\n1: subject \(kettle\), center/);
  assert.match(t, /Earlier question: What is it\?/);
  assert.match(t, /The user asks: Why won't it boil\?/);
  assert.match(userText({ image: "x", walkthrough: true }), /walkthrough for: using this/);
});
