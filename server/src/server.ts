import http from "node:http";
import Anthropic from "@anthropic-ai/sdk";
import { AnthropicBedrockMantle } from "@anthropic-ai/bedrock-sdk";
import { LENSES, SYSTEM, type Lens } from "./prompt.js";

// Provider: Anthropic API by default; set LENSI_PROVIDER=bedrock to bill your
// AWS account (uses the standard AWS credential chain + AWS_REGION).
const provider = process.env.LENSI_PROVIDER === "bedrock" ? "bedrock" : "anthropic";
const client =
  provider === "bedrock"
    ? new AnthropicBedrockMantle({ awsRegion: process.env.AWS_REGION ?? "us-east-1" })
    : new Anthropic();
const model =
  process.env.LENSI_MODEL ?? (provider === "bedrock" ? "anthropic.claude-opus-5-5" : "claude-opus-5-5");
const effort = (process.env.LENSI_EFFORT ?? "low") as "low" | "medium" | "high";
const token = process.env.LENSI_TOKEN;
const port = Number(process.env.PORT ?? 8787);
const hasCredentials =
  provider === "bedrock" || Boolean(process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN);

type AnnotateBody = {
  image: string;
  label?: string | null;
  lens?: Lens;
  question?: string;
};

function userText(body: AnnotateBody): string {
  const lens = LENSES[body.lens ?? "identify"] ?? LENSES.identify;
  const hint = body.label ? `On-device detector guess: "${body.label}" (may be wrong).` : "";
  if (body.question) {
    return `${hint}\nLens: ${lens}\nThe user asks: ${body.question}\nAnswer with A| lines (and P| lines if pointing at parts helps).`;
  }
  return `${hint}\nLens: ${lens}`;
}

async function annotate(body: AnnotateBody, res: http.ServerResponse, signal: AbortSignal) {
  const started = Date.now();
  const stream = client.beta.messages.stream(
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

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, provider, model }));
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
  for await (const c of req) chunks.push(c as Buffer);
  let body: AnnotateBody;
  try {
    body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (typeof body.image !== "string" || !body.image) throw new Error("image required");
  } catch (e) {
    res.writeHead(400).end(String(e));
    return;
  }

  console.log(`annotate lens=${body.lens ?? "identify"} label=${body.label ?? "-"}${body.question ? " q" : ""}`);
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
    let msg = hasCredentials ? "Something went wrong." : "Server has no Claude credentials.";
    if (err instanceof Anthropic.RateLimitError) msg = "Busy, try again in a moment.";
    else if (err instanceof Anthropic.AuthenticationError) msg = "Server key is not set up.";
    else if (err instanceof Anthropic.APIConnectionError) msg = "Can't reach Claude.";
    else if (err instanceof Anthropic.APIError) msg = `Claude error ${err.status ?? ""}`.trim();
    console.error(err);
    res.write(`\nE|${msg}\n`);
  }
  res.end();
});

server.listen(port, "0.0.0.0", () => {
  console.log(`lensi server on :${port} (${provider}, ${model}, effort ${effort})`);
  if (!hasCredentials) console.warn("ANTHROPIC_API_KEY is not set; requests will fail.");
});
