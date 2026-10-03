# lensi

AI for the physical world. Point your iPhone at something, tap, and Lensi outlines it and pins labels onto its parts that stay put as you move.

## How it stays fast

| Step | Where | Time |
|---|---|---|
| Find objects, track boxes | On device: YOLO11n on the Neural Engine, ~15 fps | instant |
| Outline the tapped thing | On device: Vision subject segmentation | ~150 ms |
| Anchor in 3D | On device: ARKit world tracking + raycast | instant |
| Name it, point at parts, facts | Claude, streamed line by line | first pin in ~1–2 s |

The local label shows the moment you tap. Claude's answer streams in one line at a time, and each line lands as it arrives: the title replaces the pin label, every `P|x|y|label` line drops a callout onto the object, facts fill the sheet. The camera pose is frozen at tap time, so callouts land correctly even if you moved the phone meanwhile.

## Layout

```
app/                    Expo (SDK 57) dev-build app, Expo Router
  modules/lensi-ar/     Local Expo module (Swift): ARKit view, YOLO, segmentation, pins
  src/app/index.tsx     Camera screen
  src/lib/              Streaming client, line protocol, annotation state
server/                 Node server that streams Claude annotations
```

## Run it

You need a Mac with Xcode and an iPhone with ARKit (any recent iPhone). The camera and ARKit do not work in the simulator.

1. Server:
   ```sh
   cd server
   npm install
   cp .env.example .env   # add ANTHROPIC_API_KEY, or set LENSI_PROVIDER=bedrock
   npm start              # listens on :8787
   ```
2. App (phone on the same Wi-Fi as the Mac):
   ```sh
   cd app
   npm install
   npx expo run:ios --device
   ```
   In development the app talks to the server on the machine running Metro. For a deployed server set `EXPO_PUBLIC_LENSI_SERVER=https://...`.

## Lenses

Identify, Fix (point at controls, troubleshooting steps), Shop (price range, what to check), Safe (allergens, warnings, expiry), Learn (how it works). After an annotation you can ask follow-up questions about the same object.

## Claude provider

- Default: Anthropic API, `claude-opus-5-5` at `effort: low` with server-side refusal fallback on.
- `LENSI_PROVIDER=bedrock` uses Amazon Bedrock with your AWS credentials, so AWS credits pay for it.
- `LENSI_MODEL` swaps the model, e.g. `claude-haiku-4-5` for lower latency.

## Tests

```sh
cd app && npm test && npx tsc --noEmit
cd server && npx tsc --noEmit
```
