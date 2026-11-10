# Storybook 11 architecture findings

This project is a **native iOS Storybook**: a tool for browsing, rendering and
driving SwiftUI/UIKit components in isolation, built on Storybook's ideas
rather than on its web stack. This document records what we learned about
Storybook 11's new architecture ("Open Services") and what it means for the
design here.

> **Source:** findings come from exploring the Storybook repo on the `next`
> branch (`11.0.0-alpha.6`) in October 2026. Open Services is internal and still
> changing, so check file paths and details against the current branch before
> relying on them.

## TL;DR

- Storybook 11 adds **Open Services**: typed services whose state is copied in
  every runtime (server, manager, each preview) and kept in sync with JSON
  patches and logical clocks. Alongside them sit **toolsets**, one definition
  exposed through MCP, a CLI and an SDK so agents and scripts can drive
  Storybook.
- It is **not a public API**. Storybook's `MIGRATION.md` says it's "not ready for
  third-party addons yet", and the wire protocol makes no stability promise.
- Three ways to build an iOS Storybook came out of the investigation. We can
  borrow the design and build it natively, which is the direction this project
  takes. We can use Storybook's Node dev server headless as the host and make
  the iOS app the preview. Or we can talk the raw Open Services protocol from
  Swift, which we don't recommend.

## 1. What Open Services is

Code: `code/core/src/shared/open-service/` (the design is in its `README.md`).
Services live in `services/`.

### Services: coordinating state

- **Definition:** `defineService()` takes an `id`, an `initialState` (a plain
  object), typed **queries** (synchronous reads) and typed **commands** (async
  writes).
- **Validation:** all query and command input/output is validated with
  Standard Schema.
- **Reactivity:** state is held in fine-grained signals (`deepsignal` and
  `@preact/signals-core`).
- **Registration:** a single `registerService`, re-exported for each
  environment (`storybook/manager-api`, `storybook/preview-api` and the server
  entry). Manager UI uses `useServiceQuery` and `useServiceCommand`.
- **Sync model (multi-master):**
  - Every runtime keeps its own copy of each service's state, and any copy can
    accept writes.
  - Each write is sent to the others as an **RFC 6902 JSON patch** that covers
    only the paths that changed.
  - **Lamport clocks and version vectors** put writes in the same order
    everywhere, so every copy ends up with the same state.
  - Gaps and duplicates are detected. A replica that falls behind re-syncs from
    a snapshot. A bounded log supports undo/redo.
- **Topology:** the server and manager are **hubs** that forward writes, and
  previews are **leaves**. In a static build there's no server, so the manager
  becomes the hub, and query `load` hooks produce static snapshots.
- **Remote commands:** a runtime can call a command implemented in another
  runtime. The call goes invoke → ack → result over the channel, and errors are
  serialized back to the caller.
- **Existing services:** `module-graph`, `module-graph-index`, `docgen`,
  `review`, `story-docs`.

### Toolsets: driving Storybook from outside

- Services hold internal state. **Toolsets** are the public surface for agents
  and scripts.
- Each toolset method declares input/output schemas and has one handler. That
  one definition is exposed through **MCP** (`/mcp`, via `addon-mcp`), the
  **`storybook tools` CLI** and the **`createTools` SDK**
  (`storybook/internal/tools`).
- The core toolsets are `docs`, `stories` and `review`. Addons can add their
  own; `addon-vitest` adds `test`.
- **Delegated mode:** by default the CLI attaches to a Storybook that's already
  running, and the running instance carries out the commands, sending the
  resulting state back as patches. If it can't attach, the CLI loads Storybook
  locally. You can force either behaviour with `--attach` / `--no-attach` and
  pick an instance with `--port`. See `code/core/src/cli/tools/README.md` and
  `.agents/guidelines/architecture.md` ("Open services and toolsets").
- This replaces the experimental `storybook ai <tool>` commands, which have been
  removed.

## 2. How it differs from the previous architecture

Before Open Services, state moved between runtimes in three ways:

1. **Raw channel events** (`emit` / `on`, `useChannel`). Payloads had no schema,
   and each feature wrote its own request/response handling.
2. **Manager-only state** (`manager-api` store, `useAddonState`). Anything the
   preview or server needed was sent over the channel by hand.
3. **`UniversalStore`** (`code/core/src/shared/universal-store/`), a
   leader/follower store. Each write sent the whole new state, and late joiners
   asked the leader for the current state.

| | Before (`UniversalStore` / channel) | Open Services |
| --- | --- | --- |
| Who owns state | One leader; followers mirror it | Every runtime holds a copy and can accept writes |
| What a write sends | The whole state object | An RFC 6902 patch of the changed paths |
| Ordering | Last message received wins | Lamport clocks and version vectors give one order everywhere |
| Missed messages | Initial state request on join only | Gap/duplicate detection, snapshot re-sync, undo/redo log |
| API shape | `getState`/`setState` + untyped events | Typed queries and commands |
| Validation | None | Standard Schema on all inputs and outputs |
| Reactivity | Subscribe to the whole state | Fine-grained signals |
| Cross-runtime calls | Hand-rolled with events | Built-in remote commands |
| Driving from outside | None (experimental `storybook ai`) | Toolsets via MCP, CLI and SDK, with delegated mode |

The migration isn't finished. `UniversalStore` is now internal and only accepts
four first-party store ids (`storybook/status`, `storybook/test-provider`,
`storybook/checklist`, `storybook/test`; see `first-party-store-ids.ts`). The
newer subsystems run on Open Services.

## 3. Options we considered for an iOS Storybook

### A. Talk Open Services directly from Swift: not recommended

A Swift client could join as a leaf over the WebSocket at
`/storybook-server-channel?token=…` and exchange events like
`services:sync-request`, `services:entry` and `services:command-invoke` (see
`service-channel.ts`). But that means reimplementing the whole sync algorithm
(patches, Lamport ordering, vectors, gap repair) against an internal protocol
that can change in any alpha. Open Services also only moves state; it doesn't
index or render stories.

### B. Host on Storybook's Node dev server, headless, with iOS as the preview

The dev server (`code/core/src/core-server/`) loads presets, builds the story
index, runs a builder, hosts the server channel, acts as the Open Services hub
and serves MCP. The web manager is optional, so a native app can act as the
preview and the browser:

```text
Node dev server (Storybook core, headless)
  ├─ preset: Swift indexer + Xcode builder
  ├─ GET /index.json       ──▶ iOS app builds its story list
  ├─ WebSocket channel     ◀─▶ iOS app: select / render / args events
  └─ /mcp, storybook tools ──▶ agents drive it
```

Where an iOS project plugs in:

- **Indexer:** `experimental_indexers` in a preset
  (`core-server/presets/common-preset.ts`), which could read Swift `#Preview`
  blocks or CSF files that point at iOS components.
- **Builder:** the small `Builder` interface (`types/modules/core-common.ts`).
  `start()` receives the HTTP server, router and channel, so it could run
  `xcodebuild` and boot a simulator.
- **Device connection:** a client that sends no `Origin` header and no `page`
  parameter authenticates with the token alone and gets the `server` role
  (`core-server/utils/get-server-channel.ts`). This is how the CLI attaches.
- **Index refresh:** `storyIndexInvalidated` on the channel. `storybook index`
  writes the index without starting a server, which is useful for CI.

What the native side would have to provide itself:

- **Driving the preview.** Normally the manager sends `setCurrentStory` and
  `updateStoryArgs` and the preview answers with `storyRendered`. Without the
  manager, the app does this itself, but it can reuse the same event names.
- **Story semantics.** CSF is evaluated by the JS `preview-api`: args/argTypes
  merging, globals, decorators, loaders, play functions. The index only lists
  stories.
- **Manager addons.** Controls, Actions, a11y and other panels are web UI and
  would need rebuilding natively. Server-side addons (indexing, docgen, MCP
  toolsets, test running) keep working.
- **Caveat:** some server features (review, test running, ghost stories) may
  expect a browser preview to answer them. Prototype before committing.

The trade-off is a Node dependency in an iOS developer workflow, in exchange
for Storybook's ecosystem and agent tooling.

### C. Borrow the design and build natively: this project's direction

Take the ideas that work and implement them in Swift, without depending on
Storybook's runtime or wire protocol. The next section describes how.

## 4. Ideas to borrow for a native iOS Storybook

Each Storybook concept, with how it could map to this project. These are
proposals, not decisions yet.

| Storybook concept | Native iOS translation |
| --- | --- |
| Story index (`index.json`: id, title, name, import path, tags) | A stable story manifest generated from Swift sources (e.g. `#Preview` blocks or a `Story` protocol), available at build time and at runtime |
| Indexers (pluggable story discovery) | Pluggable discovery: a Swift macro/SwiftSyntax scanner, with room for other sources later |
| CSF args / argTypes | Typed, `Codable` args with control metadata, kept deliberately small at first |
| Decorators / globals | View modifiers and environment values (color scheme, Dynamic Type, locale, device) applied around a story |
| `defineService()` with typed queries and commands | Services as Swift types with synchronous query methods and `async` command methods; `Codable` inputs/outputs give schema validation for free |
| Signals-based reactivity | `@Observable` (Observation framework) |
| Multi-master replicas synced by JSON patches with logical clocks | Only if we need several live runtimes (e.g. a Mac host app plus a simulator/device). Start with one authority and patch-based updates; add clocks/vectors only if concurrent writers appear |
| Hub / leaf topology | Host (Mac app or CLI) as hub; each simulator/device preview as a leaf |
| Remote commands (invoke → ack → result, serialized errors) | A small typed RPC layer over a local WebSocket / Bonjour connection between host and device |
| Toolsets: one schema-described definition exposed via MCP, CLI and SDK | Define each tool once (e.g. `listStories`, `renderStory`, `setArgs`, `snapshot`) and expose it through an MCP server, a Swift CLI and a library API |
| Delegated mode (CLI attaches to a running instance, else runs locally) | The CLI attaches to a running host/simulator if it finds one, otherwise launches one, with explicit `--attach` / `--no-attach` |
| Static builds (manager becomes hub, `load` snapshots) | A standalone mode where the app works with no host, using a bundled manifest |
| Manager addons (Controls, Actions, a11y) | Native panels in the browser UI, built on the same services |

Lessons from the old architecture, worth keeping in mind from day one:

- Give messages schemas. Untyped events led to a separate hand-rolled protocol
  for each feature.
- Don't send the whole state on every write. Send diffs, and handle late joiners
  and missed messages explicitly.
- Keep internal state (services) separate from the public automation surface
  (toolsets), so the internals can change without breaking agents and scripts.

## 5. Open questions

- **Story source:** reuse SwiftUI `#Preview`, define our own `Story` API, or both?
- **Where previews run:** in-process in the browsing app, in a separate
  simulator/device app, or both?
- **Host:** a Mac app, a Swift CLI, or optionally Storybook's Node server
  (option B) for teams that want web-ecosystem integration?
- **Protocol:** how much of the sync model do we need? Is one authority with
  patches enough?
- **Compatibility:** should the manifest and tool names follow Storybook's
  (`index.json` shape, `stories`/`docs` toolset names) so agents that know
  Storybook can drive this tool too?
- **Open Services going public:** watch Storybook's `MIGRATION.md`. If it opens
  to third-party addons with a stable protocol, revisit option A/B.

## Key references in the Storybook repo (`next`)

- `code/core/src/shared/open-service/README.md`: Open Services design
  (sections "State Sync (Multi-Master)" and "Delegated mode")
- `code/core/src/shared/open-service/service-channel.ts`: wire events
- `code/core/src/shared/universal-store/`: the previous leader/follower store
- `code/core/src/cli/tools/README.md`: `storybook tools` and `createTools`
- `.agents/guidelines/architecture.md`: "Open services and toolsets"
- `code/core/src/core-server/`: Node dev server, presets, server channel,
  `index.json`
- `MIGRATION.md`: `UniversalStore` made internal, `storybook ai` removed, Open
  Services status
