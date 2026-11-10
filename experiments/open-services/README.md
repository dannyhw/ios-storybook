# iOS Storybook on Storybook 11 Open Services

This is an experiment. The question it answers: how far can a **non-JS framework** plug into Storybook 11 by following its contracts? It doesn't patch core, and it uses only published packages (`storybook@11.0.0-beta.1`). The setup:

- The native runtime from this repository's root package ([`../../README.md`](../../README.md)) renders the stories.
- Storybook's Node dev server is the hub.
- The Swift app joins it as an Open Services peer.

Checked on 2026-11-10 with an iPhone 17 simulator (iOS 27) and Node 26.

> **Headless version:** [HEADLESS.md](HEADLESS.md) drops the browser and drives the device only from Storybook's Node server (`storybook tools`, `createTools`, MCP). It splits out a framework-neutral `storybook-remote-renderer` package.

## How it fits together

```text
                    Storybook 11 dev server (Node, unpatched)
   ┌──────────────────────────────────────────────────────────────────────┐
   │ storybook-ios framework preset                                       │
   │   experimental_indexers ─ static Swift reader → index.json           │
   │   viteFinal ─ *+Stories.swift → CSF module (argTypes from manifest)  │
   │   services ─ ios/bridge (handlers), ios/device (no handlers),        │
   │              `ios` toolset                                           │
   │   experimental_docgenProvider / experimental_storyDocsProvider       │
   │   experimental_serverChannel ─ token → simctl launch, action relay   │
   └──────────────┬─────────────────────────────┬─────────────────────────┘
       /storybook-server-channel (WebSocket)    │ /mcp, storybook tools
          ┌───────┴───────┐             ┌───────┴────────┐
   web manager + preview iframe         Swift app (OpenServicesPeer)
   proxy renderToCanvas → ios/bridge    answers ios/device commands
   .render → hub → ios/device.render    calls ios/bridge.deviceConnected,
   → PNG in the canvas                  deviceEvent (actions), heartbeat
```

| Path | What it is |
| --- | --- |
| `packages/storybook-ios/` | The framework: preset, Swift reader, proxy renderer, manager panel, service contracts, `ios` toolset, docgen provider (about 630 lines of JS). |
| `swift/` | `StorybookOpenServices`: the Open Services peer in Swift (about 290 lines). It reuses `ios-storybook`'s store, renderer and toolset unchanged. |
| `Host/` | XcodeGen sidecar app (`dev.storybook.openservices`) for the sample design system. |
| `.storybook/main.js` | Points the framework at the sample stories and at a simulator. |

The only change the experiment needed in the root package is one line in `Package.swift` that exports `StorybookProtocol` as a library product.

## Running it

```sh
npm install
(cd Host && xcodegen generate && xcodebuild -scheme OpenServicesHost \
  -destination 'id=<udid>' -derivedDataPath build build)
xcrun simctl install <udid> Host/build/Build/Products/Debug-iphonesimulator/OpenServicesHost.app
npm run storybook   # relaunches the app on $STORYBOOK_IOS_SIMULATOR (default: the booted simulator), pointed at the server
npx storybook tools ios devices
npx storybook tools ios render --storyId design-system-pay-button--primary
```

## What worked through Storybook's contracts

Everything below was checked against the running simulator. Render times are measured on the device.

| Capability | Storybook hook used | Result |
| --- | --- | --- |
| Framework without its own builder | `<pkg>/preset` with `core.builder: builder-vite`; the framework is its own renderer | ✅ No core changes. |
| Sidebar from Swift files | `experimental_indexers` and the `stories` glob | ✅ All 13 stories. Ids match the native ids exactly, because `ios-storybook` ports Storybook's `toId`. |
| Controls from native argTypes | Vite `load` turns `*+Stories.swift` into CSF; the argTypes come from what the device reports | ✅ Text, select, boolean and color controls. |
| Web preview of native rendering | `previewAnnotations` → async `renderToCanvas` calls `ios/bridge.render` and shows the PNG | ✅ About 60–90 ms per render. Control edits re-render on the device, and the app mirrors the web selection. |
| Toolbar globals → native traits | `globalTypes` in the renderer entry | ✅ Dark mode, Dynamic Type and RTL render natively. |
| Device taps → Actions panel | Device calls `ios/bridge.deviceEvent`; the server emits `storybook/actions/action-event` | ✅ Tapping Pay in the simulator logged `onTap` in the web Actions panel. |
| Shared state across runtimes | `ios/bridge` service state, read in the manager with `useServiceQuery` | ✅ The "iOS devices" panel updates live with no sync code of ours. |
| Device implementing commands | The server registers `ios/device` without handlers; Swift acks and answers `services:command-invoke` | ✅ A minimal Swift leaf (no clocks, no vectors) is enough. |
| Agent tools | `registerToolset` from the `services` hook | ✅ `storybook tools ios devices / render / select / set-args / actions`, attached to the running server. |
| Core toolsets on iOS stories | `stories.preview`, `review.create` | ✅ They only need the index. Over MCP, `stories-preview` embeds the web preview, so agents see native renders. |
| Component docs | `experimental_docgenProvider` (Swift `///` comments plus native argTypes) and `experimental_storyDocsProvider` (Swift snippets) | ✅ `docs list / show / show-story` work over the CLI and `/mcp`. |
| Static build | `storybook build` | ✅ It compiles (13 stories), but renders need a device link it doesn't have (see gap 9). |

Per story, a framework author writes no JavaScript: the Vite plugin builds the CSF module from the Swift file.

## What's missing

These are ranked by how much they block "a new framework is just an implementation of a contract". Each gap was hit in this experiment and needed a workaround.

1. **Third-party toolsets never reach MCP.** `@storybook/addon-mcp` exposes a hard-coded list of core methods (`tool-registry.ts`). The `ios` toolset appears in `storybook tools` and `createTools`, but not on `/mcp`. *Ask:* expose every `getRegisteredToolsets()` method, possibly opt-in per toolset.
2. **Toolsets can't return images.** `ToolsetOutcome.markdown` is text only, so `ios render` writes a temp file and returns its path. For native renderers the screenshot *is* the output. *Ask:* allow image (and resource) content blocks in outcomes.
3. **Remote commands have no routing and aren't relayed between clients.**
   - **Routing:** a handler-less command is broadcast to every peer, every implementer runs it, and the first answer wins. The device filters on a `deviceId` in the input.
   - **No relay:** the preview and attached CLIs can't reach the device directly, because invokes aren't relayed peer to peer. Every call goes preview → `ios/bridge` handler on the hub → `ios/device`.
   - *Ask:* let a runtime advertise that it handles a command, let callers target a runtime, and have hubs relay invokes to the peers that advertised.
4. **No presence.** The server can't tell which runtimes are connected, or when one leaves. The experiment adds `deviceConnected` and `heartbeat` commands and expires devices after 15 s. *Ask:* a runtime list and connect/disconnect hooks in the service registry.
5. **Replicas don't sync before handlers run.** In an attached `storybook tools` process, `queries.devices.get()` returns `initialState`: the handler runs before the first sync arrives, about 250 ms later. `loaded()` doesn't wait for that sync. The workaround is a hub command (`listDevices`). *Ask:* an awaitable "synced" point (for example, `loaded()` waits for the first sync reply).
6. **The wire protocol isn't a contract.** The `services:*` events, telejson framing, the 300 ms ack deadline, and the rule that the hub only replies to a sync request after it has written state are all internal. A Swift peer needs about 250 lines, but against an alpha/beta protocol with no stability promise. `describeService` doesn't give `initialState` or JSON schemas, so a non-JS peer has to hard-code them. *Ask:* a documented, versioned "leaf peer" subset (invoke/ack/result, snapshot plus entries) with JSON Schema for each service.
7. **Story metadata only flows through a JS preview.**
   - The index can't carry args, argTypes or parameters, so Controls get them only from the preview's `storyPrepared`.
   - The preview `import()`s every `importPath` as a CSF module.
   - So a native framework must generate JS modules and run a browser preview just to describe its stories.
   - *Ask:* a server-side story-metadata path (a service or index extension) that the manager can read directly.
8. **The renderer contract is DOM-shaped.** `renderToCanvas(context, canvasElement)` assumes the story renders in the iframe. Native stories become a proxy that shows a PNG; you can't tap the image to interact. A live view would need simulator video streaming (for example WebRTC). *Ask:* a generic "remote renderer" in core, where render calls go to a peer and come back as an image or stream. Every native framework (iOS, Android, Flutter, React Native) would reuse it.
9. **Static builds have no device channel.** `experimental_serverChannel` and the WebSocket transport don't exist in `storybook build`, so the proxy renderer has nothing to call. Enabling docgen also makes the build require `experimental_manifests` component metadata (`components.meta.docgen`). The experiment turns docgen off outside dev.
10. **Small papercuts:**
    - **Preset loaded twice:** naming the framework package as its own `core.renderer` loads its preset twice (`OpenServiceDuplicateToolsetError`). Leave `core.renderer` unset.
    - **Manager `registerService` at module top level throws** (`OpenServiceMissingChannelError`) because the manager has no channel yet. Register inside `addons.register`.
    - **`storybook/open-service` isn't a manager/preview global**, so a shared definition file that imports `defineService` would bundle a second copy into the browser. The definitions here are plain objects.
    - **Reserved words:** Swift story names can be JS reserved words (`static let new`), so generated CSF exports use aliases.
    - **`experimental_serverChannel` isn't in `StorybookConfigRaw`.** The channel token reaches a preset only through `globalThis.STORYBOOK_WEBSOCKET_TOKEN`.
    - **Save-story button:** the Controls "Update story" button appears for these stories. Writing CSF back into a `.swift` file would be wrong, and there's no framework hook to turn it off. (Not clicked.)
11. **JS-only features stay JS-only.** These need native equivalents:
    - play functions and Interactions;
    - `test.run`, which runs Vitest in browser Chromium;
    - `stories.changed` and `findByComponent`, which need a builder change-detection adapter plus a Swift import graph (SwiftPM targets rather than files).

## Is it worth it?

**As an optional integration layer, yes. As the foundation, not yet.**

- **What the bridge buys:** about 920 lines (630 JS, 290 Swift) on top of the native runtime gave iOS stories:
  - the web manager, with Controls, Actions and toolbar globals;
  - docs and review tooling;
  - `stories-preview` and docs over MCP;
  - one agent CLI shared with web projects.

  The native runtime was reused unchanged. That's a strong return, and it shows that the Open Services *model* (a typed service whose commands run where the capability lives, with state synced everywhere) fits a native device well.
- **What it costs:**
  - **Spread-out contract:** a framework author has to touch about 12 hooks, half of them `experimental_` or `internal/`, plus an undocumented wire protocol.
  - **Node in the loop:** the bridge adds a Node dev server to an iOS workflow.
  - **Missing in static builds:** the most useful part, live device rendering, is absent from static Storybooks.
- **What would make it a real contract:** gaps 1–3 and 6–8. With MCP exposure plus image outputs, a documented peer protocol with routing and presence, and server-side story metadata, a new native framework would be just three things:
  - an indexer;
  - a device peer;
  - optionally a toolset.

  The web proxy renderer and CSF generation could then ship once in core and serve every native platform.

**Recommendation:**

1. Keep `ios-storybook`'s standalone path (no Node) as the default.
2. Ship this bridge as an optional `storybook-ios` framework for teams that already run Storybook.
3. Take gaps 1, 2, 3 and 8 to the Storybook team as concrete proposals; this repo is the reproduction for each.
