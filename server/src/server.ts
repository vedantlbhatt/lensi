import http from "node:http";
import { pathToFileURL } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { AnthropicBedrockMantle } from "@anthropic-ai/bedrock-sdk";
import { SYSTEM, userText, type AnnotateBody } from "./prompt.js";
import { mockLines } from "./mock.js";

// Provider: Anthropic API by default; set LENSI_PROVIDER=bedrock to bill your
// AWS account (uses the standard AWS credential chain + AWS_REGION).
// LENSI_MOCK=1 streams a scripted answer without calling any model, for
// testing the app <-> server protocol.
const mock = process.env.LENSI_MOCK === "1";
const provider = mock ? "mock" : process.env.LENSI_PROVIDER === "bedrock" ? "bedrock" : "anthropic";
const model =
  process.env.LENSI_MODEL ?? (provider === "bedrock" ? "anthropic.claude-opus-5-5" : "claude-opus-5-5");
const effort = (process.env.LENSI_EFFORT ?? "low") as "low" | "medium" | "high";
const token = process.env.LENSI_TOKEN;
const port = Number(process.env.PORT ?? 8787);
const MAX_BODY = 16 * 1024 * 1024;
const hasCredentials =
  provider !== "anthropic" || Boolean(process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN);

let client: Anthropic | AnthropicBedrockMantle | null = null;
function getClient() {
  client ??=
    provider === "bedrock"
      ? new AnthropicBedrockMantle({ awsRegion: process.env.AWS_REGION ?? "us-east-1" })
      : new Anthropic();
  return client;
}

async function annotate(body: AnnotateBody, res: http.ServerResponse, signal: AbortSignal) {
  const started = Date.now();
  if (mock) {
    for (const line of mockLines(body)) {
      if (signal.aborted) return;
      await new Promise((r) => setTimeout(r, 40));
      res.write(`${line}\n`);
    }
    return;
  }
  const stream = getClient().beta.messages.stream(
    {
      model,
      max_tokens: 2048,
      output_config: { effort },
      system: [{ type: "text", text: SYSTEM, cache_control: { type: "ephemeral" } }],
      messages: [
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: "image/jpeg", data: body.image } },
            { type: "text", text: userText(body) },
          ],
        },
      ],
      // Server-side fallback on refusal is a first-party API feature only.
      ...(provider === "anthropic"
        ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const }
        : {}),
    },
    { signal },
  );

  let first = true;
  for await (const event of stream) {
    if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
      if (first) {
        first = false;
        console.log(`  first token ${Date.now() - started}ms`);
      }
      res.write(event.delta.text);
    }
  }
  const final = await stream.finalMessage();
  if (final.stop_reason === "refusal") res.write("\nE|Can't annotate this one.\n");
  console.log(`  done ${Date.now() - started}ms, ${final.usage.output_tokens} out`);
}

function errorLine(err: unknown): string {
  if (!hasCredentials) return "Server has no Claude credentials.";
  if (err instanceof Anthropic.RateLimitError) return "Busy, try again in a moment.";
  if (err instanceof Anthropic.AuthenticationError) return "Server key is not set up.";
  if (err instanceof Anthropic.APIConnectionError) return "Can't reach Claude.";
  if (err instanceof Anthropic.APIError) return `Claude error ${err.status ?? ""}`.trim();
  return "Something went wrong.";
}

export function createServer() {
  return http.createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/health") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, provider, model: mock ? "mock" : model }));
      return;
    }
    if (req.method !== "POST" || req.url !== "/annotate") {
      res.writeHead(404).end();
      return;
    }
    if (token && req.headers.authorization !== `Bearer ${token}`) {
      res.writeHead(401).end();
      return;
    }

    const chunks: Buffer[] = [];
    let size = 0;
    for await (const c of req) {
      size += (c as Buffer).length;
      if (size > MAX_BODY) {
        res.writeHead(413).end("image too large");
        return;
      }
      chunks.push(c as Buffer);
    }
    let body: AnnotateBody;
    try {
      body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (typeof body.image !== "string" || !body.image) throw new Error("image required");
    } catch (e) {
      res.writeHead(400).end(String(e));
      return;
    }

    const kind = body.check ? "check" : body.walkthrough ? (body.guide ? "guide" : "walk") : body.question ? "ask" : "annotate";
    console.log(`${kind} lens=${body.lens ?? "identify"} label=${body.label ?? "-"}`);
    res.writeHead(200, {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-cache",
      "x-accel-buffering": "no",
    });
    const abort = new AbortController();
    res.on("close", () => abort.abort());

    try {
      await annotate(body, res, abort.signal);
    } catch (err) {
      if (abort.signal.aborted) return;
      console.error(err);
      res.write(`\nE|${errorLine(err)}\n`);
    }
    res.end();
  });
}

// Run when executed directly (npm start), not when imported by tests.
if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  createServer().listen(port, "0.0.0.0", () => {
    console.log(`lensi server on :${port} (${provider}, ${mock ? "mock" : model}, effort ${effort})`);
    if (!hasCredentials) console.warn("ANTHROPIC_API_KEY is not set; requests will fail.");
  });
}
