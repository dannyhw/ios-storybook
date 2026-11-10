# Headless: driving native stories from Storybook's Node server

The [README](README.md) experiment put iOS stories into the web Storybook. This one removes the browser entirely. It runs Storybook 11's Node dev server with **no manager and no preview iframe**, and drives a native renderer only through Open Services, `storybook tools`, the tools SDK and MCP. Everything runs on published `storybook@11.0.0-beta.1` with no core patches.

[Watch the demo](../../docs/videos/open-services-experiment.mp4): the first half is this headless setup.

It also separates the **contract** from the framework, to see how small the iOS-specific part can be:

| Package | What it is | Lines |
| --- | --- | --- |
| `packages/storybook-remote-renderer` | Framework-neutral and reusable for any native renderer. It provides the `remote-renderer/peer` and `remote-renderer/hub` service contracts, a stub builder, the `device` toolset, and an MCP endpoint that exposes every toolset and returns images. | ~440 |
| `packages/storybook-ios-headless` | Everything iOS-specific: a Swift story indexer, a docgen hookup, and launching the simulator app. | 65 |
| `swift/` `OpenServicesPeer` | The peer. The same Swift client as before, now speaking either contract (`-StorybookContract remote-renderer`). | ~260 |

A new native framework (Android, Flutter, React Native) would write only the middle row plus its own peer.

## Running it

```sh
npm run storybook:headless            # storybook dev -c .storybook-headless --preview-only -p 6007
npx storybook tools -c .storybook-headless device list
npx storybook tools -c .storybook-headless device story --storyId design-system-pay-button--primary
npx storybook tools -c .storybook-headless device set-args --storyId design-system-pay-button--primary --args '{"title":"Headless"}'
npx storybook tools -c .storybook-headless device set-globals --globals '{"colorScheme":"dark"}'
npx storybook tools -c .storybook-headless device render --storyId design-system-pay-button--primary --outPath pay.png
node scripts/render-all.mjs renders/  # every story, light and dark, through createTools
# MCP (all toolsets, image results): POST http://127.0.0.1:6007/mcp-all
```

## What the server does with no browser

```text
 agent / script ──storybook tools · createTools · POST /mcp-all──┐
                                                                  ▼
              Storybook 11 dev server (--preview-only, stub builder)
              index.json ← Swift indexer        docs ← Swift docgen provider
              remote-renderer/hub (handlers, state: peers, stories, actions)
              remote-renderer/peer (no handlers → broadcast to peers)
                                                                  │ /storybook-server-channel
                                                                  ▼
                                             iOS app: OpenServicesPeer → native renderer
```

All of these were checked on 2026-11-10 against an iPhone 17 simulator (iOS 27):

| Capability | Result |
| --- | --- |
| Boot without a browser | ✅ `--preview-only` plus a stub builder. `/` and `/iframe.html` return 404; `/index.json` serves 13 stories. |
| Static index for CI | ✅ `storybook index -c .storybook-headless` writes all 13 entries without a device. |
| Story metadata without a preview | ✅ `device story` reads argTypes, initial args and current args from **hub state**, reported by the peer. In the web version only the browser preview could provide these. |
| Drive args and globals from Node | ✅ `device set-args`, `reset-args` and `set-globals` change the native store. |
| Render from Node | ✅ 26 renders (13 stories in light and dark) from a `createTools` script in 2.2 s, **85 ms each, 79 ms of that on the device**. The Open Services hop (script → server → device) costs about 6 ms. |
| Device → server events | ✅ A tap on the simulator appears in `device actions` from hub state. |
| Attached CLI with no `--port` | ✅ Finds the running instance through Storybook's instance registry. |
| Docs | ✅ `docs list` and `docs show` from Swift `///` comments plus native argTypes. |
| MCP | ✅ through this package's `/mcp-all`: 15 tools (core plus `device`), and `device-render` returns an **image** content block. |

## What's missing, for headless specifically

1. **Story metadata has no place in core.** The hub's `stories` state works, but only this package knows about it.
   - The index can't carry args or argTypes.
   - Core's docs toolset gets argTypes only through a docgen provider. That provider runs in a worker thread that can't read service state, so peers' metadata also has to be cached to a file for it.
   - *Ask:* a server-side story-metadata service in core (args, argTypes, parameters per story) that the manager, docs and toolsets all read. For a JS framework, the preview would fill it; for a remote renderer, the peer would.
2. **MCP doesn't serve third-party toolsets or images.** The fix took about 110 lines (`mcp.js`): iterate `getRegisteredToolsets()`, convert schemas with `@valibot/to-json-schema`, and map a `data.image` convention to image content. `@storybook/addon-mcp` could do this directly.
3. **Routing, relay and presence** are as before (README gaps 3–5). Every tool call goes through a hub command (`call`, `snapshot`), because:
   - invokes aren't relayed between clients;
   - an attached replica hasn't synced when a handler runs.

   Peers are tracked with heartbeats because the registry has no presence.
4. **Core toolsets assume a web UI.** In headless mode, `stories preview` and `review create` still return `http://127.0.0.1:6007/?path=…` links, which 404 because there's no manager. *Ask:* toolsets should know when no UI is served, and either hide those methods or say so.
5. **"Headless" isn't a supported mode:**
   - **Builder required:** the dev server throws without a `core.builder`, so this ships a stub builder. Its `totalTime` has to be a duration from `startTime`, or Storybook prints "233 h for preview".
   - **Builder-adjacent preset loaded twice:** in the `storybook tools` path, `loadStorybook` also loads any `preset.js` next to the builder module as a preset. A stub builder beside the package's own `preset.js` therefore applied that preset twice (`OpenServiceDuplicateToolsetError`). The builder now lives in `src/builder/`.
   - **Misleading flag name:** `--preview-only` actually means "no manager". With a stub builder, nothing is served at all.
   - *Ask:* an explicit `core.builder: false` / `--headless` mode.
6. **Change detection is off.** Without a builder change-detection adapter, `stories changed` and `find-by-component` can't work. A Swift adapter would need SwiftPM's target graph, because Swift files don't import each other.
7. **Contract stability (unchanged from before).** The peer side is ~260 lines of Swift against internal `services:*` events. The server side uses `storybook/internal/core-server` (`experimental_registerService`, `getService`) and `experimental_*` preset hooks. Only `storybook/open-service` (`defineToolset`, `registerToolset`, `getRegisteredToolsets`) and `storybook/internal/tools` (`createTools`) are meant for third parties, and even `internal/tools` is under `internal/`.

## What it shows

**Driving native stories from Storybook's Node server works today, and the contract can be framework-neutral.**

- **Small per-framework part:** iOS adds an indexer and a launch hook (65 lines) on top of a generic layer. That layer was never told about iOS.
- **Benefit:** agents and scripts get one surface for native and web stories: the same CLI, SDK, docs tools, and (with a better MCP addon) the same MCP server.
- **Speed:** renders from Node add about 6 ms over the device's own time.

**What stops it being a real contract is mostly in Storybook, not in the framework:**

- a home for story metadata outside the browser (gap 1);
- MCP that serves every toolset and images (gap 2);
- routing and presence for peers (gap 3);
- an official headless mode (gap 5);
- a stable, documented peer protocol (gap 7).

If Storybook shipped `storybook-remote-renderer`'s pieces in core (the hub/peer contract, the `device` toolset and the MCP behaviour), adding a native framework would come down to an indexer, a peer, and how to launch it.
