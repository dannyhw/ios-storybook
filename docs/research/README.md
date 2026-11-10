# Research overview: a native iOS Storybook

This directory has four research reports, plus this summary of what they
found and where they disagree. Read
[`../storybook-11-architecture-findings.md`](../storybook-11-architecture-findings.md)
first for the Storybook 11 background.

| # | Report | Question it answers |
| --- | --- | --- |
| 01 | [Landscape](01-landscape.md) | What exists for iOS component catalogs and design systems, and where are the gaps? |
| 02 | [Story format](02-story-format.md) | Do we want a Swift CSF, and what should it look like? |
| 03 | [Discovery and host app](03-discovery-and-host-app.md) | How does the app find stories, where does it run, and how do tools talk to it? |
| 04 | [Supporting tooling](04-supporting-tooling.md) | Testing, a11y, controls, docs, Figma/tokens, agents/MCP, CI and distribution |

> Researched on 2026-10-17 against Xcode 27.0 (27A266a) and Swift 6.3/6.4.
> Each report marks claims it couldn't verify.

## The opportunity in one paragraph

On iOS, `#Preview` is where developers already write component states, and the
active tools (SnapshotPreviews, Prefire, Xcode's own `RenderPreview` MCP tool)
all **harvest previews for static snapshots**. Nobody offers what makes
Storybook Storybook:
- **typed, per-prop controls** you can edit live;
- an **actions log**;
- a **stable, documented story index** shared by tools and agents;
- **decorators and globals** as a first-class concept;
- **component docs pages**;
- a **catalog-level agent toolset** (list, render with args, set args,
  snapshot, a11y) that works on a simulator or device without Xcode open.

The big public design systems (Fluent UI Apple, Backpack, OUDS, Spark, SBB)
each hand-build and maintain their own demo app. That is the work this project
replaces.
React Native Storybook (on-device controls, WebSocket sync, `/mcp`) shows the
experience users want. There is no native equivalent. (01 §6, 04 §4)

## Consolidated recommendations

### 1. Story format: own a Swift "CSF Next", and import `#Preview`

**Copy CSF's data model, not its JS syntax** (02):
- meta → stories, with args merged in the order project → meta → story;
- argTypes, decorators, parameters, loaders, play functions and tags;
- ids built as `sanitize(title)--sanitize(startCase(memberName))`.

**The core is plain Swift, with a protocol and an optional macro:**

```swift
@Stories(title: "Design System/Pay Button", tags: ["autodocs"])
enum PayButtonStories {
    static let meta = StoryMeta(args: PayButtonArgs()) { PayButton($0) }
    static let primary  = meta.story()
    static let disabled = primary.extend(name: "Disabled state") { $0.isEnabled = false }
}
```

**How the pieces work:**
- **Args are a `Codable` struct.** Controls are derived from the property types
  (`String`, `Bool`, numbers, `CaseIterable` enums, `Optional`, `StoryColor`,
  `StoryAction`), and an `@Arg(...)` wrapper can override the control.
  `Codable` gives JSON `setArgs` for MCP and the wire protocol at no extra cost.
- **The `@Stories` macro is optional sugar.** It:
  - generates the list of stories;
  - requires titles, names and tags to be literals, so the static indexer is
    always right;
  - records doc comments and source lines;
  - emits a discovery record (see §2).
- **`#Preview` becomes an importer** that produces read-only stories tagged
  `preview`. It is not the primary format, because previews have no editable
  args, no play function and no stable id for unnamed previews.
- **Storybook's id and tag functions are ported exactly.** Use Storybook's own
  test vectors, and emit `index.json` v5 with `argTypes` in Storybook's shapes,
  so Storybook-aware agents and tools can read the manifest.

**What changed in Xcode 27, verified in the local SDK:**
- `#Preview(_:traits:arguments: [T]) { (T) -> View }` exists (iOS 26+).
- `PreviewProvider` is deprecated.

`arguments:` is a **static array of values**. It gives a grid of variants, not
editable controls. It strengthens the `#Preview` importer (one story per
argument value, perhaps) without replacing the typed-args format. Threads 01
and 04 disagreed on this, and the SDK settles it. (04 TL;DR, 01 §1.1)

### 2. Discovery: runtime records first, plus a static index

**At runtime, the app tries these in order** (03 §7.2):
1. **`@section("__DATA_CONST,__swift5_story") @used` records** emitted by
   `@Stories` (SE-0492, Swift 6.3+). This is the mechanism Swift Testing uses
   for `@Test` and Apple's `#Playground` uses for playgrounds. It needs no
   private API.
2. **A `__swift5_proto` scan for conformances to *our own* `Stories`
   protocol.** This covers code without the macro or with older toolchains.
3. **`Storybook.register(...)`, written by hand or generated.** This is the
   escape hatch.
4. **An optional `#Preview` importer.** It relies on private
   `DeveloperToolsSupport` layout, like SnapshotPreviews, so it sits behind a
   flag.

**Statically:**
- A SwiftSyntax CLI (`storybook index`) builds `index.json` without compiling,
  for agents, CI and the host's story list.
- The running app compares its runtime index with the static one and reports
  any drift.

**Macros alone can't do discovery.** A macro only sees its own declaration, so
it can only *emit* records for a runtime scan to find. (03 §1.1)

### 3. Host app: a package plus a host target, or embedded in a debug build

**Supported from day one, with one runtime** (03 §3):
- **(a) An `<App>Storybook` app target in the user's project**, created by
  `storybook init`. It links the modules that contain stories. This is the
  primary model.
- **(d) The same runtime embedded in the user's Debug or internal build**, for
  stories that live in the app target or need the real app's environment.

**Rejected or deferred:**
- **A generic prebuilt host that `dlopen`s user code.** It only works on the
  simulator. On devices running iOS 18 and later, dylibs outside the app bundle
  are refused even when signed by the same team. It also breaks on resources and
  dependencies, so at most it's a simulator-only quick-look experiment.
- **A Mac app.** It comes later, as one more client of the CLI/daemon toolset.
  Embedding the simulator needs private APIs.

**Rendering happens in the app process:**
- Each render gets a fresh `UIHostingController` or UIKit container. Sizing
  modes are `fullscreen`, `sizeThatFits`, `fixed` and `padded`/`centered`.
- Decorators apply through the SwiftUI environment plus UIKit `traitOverrides`.
- The renderer waits for the layout to settle, then captures with
  `drawHierarchy`. For full-device frames it uses `simctl io screenshot`.

**Correction to 04 §7.5:** don't use `ImageRenderer` as the general capture
path. It draws placeholders for UIKit-backed views. (03 §5.5)

### 4. Iteration speed: tiered hot reload

| Tier | What | Where |
| --- | --- | --- |
| 0 | Args, globals and story selection over the socket. No code reload. | Everywhere, instant |
| 1 | File watch, then incremental `xcodebuild`, then relaunch that restores the story and args from launch arguments | Simulator and device, seconds |
| 2 | Optional InjectionNext integration | Simulator only |
| — | Xcode Previews' JIT | Not available. It relies on a private "Preview" code-signature type. |

Ship tiers 0 and 1. Make "code changed, re-render" an event from the start, so
tier 2 can be added later. (03 §4)

### 5. Wire protocol and agent surface: Storybook 11 toolsets, natively

**Transport:**
- The app runs a WebSocket server on `localhost`.
  - On the simulator, the Mac shares its network stack, so the CLI connects
    directly.
  - On a device, the CLI connects over USB (`iproxy`) or the LAN. Because the
    app accepts the connection rather than opening one, there is **no
    local-network prompt** (TN3179).
- Server library: 03 suggests Network.framework `NWListener`, and 04 suggests
  FlyingFox. Either works; prototype with `NWListener` to avoid a dependency.
- Messages are typed `Codable` structs that follow the invoke → ack → result
  shape, plus events (`storyRendered`, actions).
- **One authority:** the app owns render state and the daemon forwards. Add
  per-service versions only when two writers (a Mac UI and an agent) appear.
  (03 §6, findings doc §4)

**Toolsets** follow Storybook's `defineToolset` shape and tool names, so agents
that know Storybook already know these. Each one is defined once and exposed
through MCP, the CLI and a Swift SDK (04 §7.5):

| Toolset | Methods |
| --- | --- |
| `stories` | `list`, `findByComponent`, `changed`, `select`, `render` (args + variant, returns a PNG) |
| `args` | `get`, `set`, `reset` |
| `docs` | `list`, `show`, `showStory` |
| `test` | `run`, `a11y.audit`, `a11y.voiceOver` |
| `actions` | `list`, `clear` |
| `review` | `create` (Storybook's schema) |

**Delegated mode:** attach to a running app or daemon, otherwise build and
launch. Force either with `--attach` / `--no-attach`, and record running
instances in a file, as Storybook does with `instances/*.json`.

**Don't build a UI driver.** Delegate taps and gestures to agent-device, AXe,
MobileBuildMCP or Xcode 27's MCP. When Xcode is open, pass `#Preview` rendering
through to Xcode's `RenderPreview` instead of competing with it.

### 6. Build vs. integrate vs. skip (04, MVP plan)

| Build (unique to us) | Integrate | Skip |
| --- | --- | --- |
| Story format, runtime and index/manifest | swift-snapshot-testing as the diff engine | Our own diff engine or hosted visual-regression service |
| WebSocket channel, toolsets, CLI and MCP | AccessibilitySnapshot (VoiceOver panel), `performAccessibilityAudit` | Our own tap driver or hot reload |
| Native Controls and Actions panels | Sentry Snapshots and reg-cli as consumers of a PNG + JSON sidecar directory | CocoaPods (trunk goes read-only on 2026-12-02) |
| Decorators/globals (scheme, Dynamic Type, Bold Text, RTL, locale) | agent-device, AXe, MobileBuildMCP, Xcode MCP | Code Connect's deprecated SwiftUI DSL |
| A `StorybookTesting` parameterized Swift Testing suite (`@Test(arguments:)`) over the index | Style Dictionary 5 or Terrazzo for DTCG tokens | Archived libraries: GTXiLib, A11yUITests, iOSSnapshotTestCase, SwiftGen, Sourcery |
| A static HTML gallery (review page, designer link, Figma back-link) | SPM + `.artifactbundle` + a signed Homebrew tap | Xcode Source Editor Extensions |

**Deferred until after the MVP:**
- play-function DSL that runs both in-process and through XCUITest/AXe;
- generating Code Connect `.figma.ts` templates from the manifest, and a
  Figma screenshot panel;
- DocC integration;
- physical-device extras (Bonjour, `devicectl` settings);
- a Mac app and multi-device sync.

## Architecture at a glance

```text
 Mac ─────────────────────────────────────────────────────────────────────────
  storybook CLI / daemon
   ├─ index      SwiftSyntax → index.json + component manifest (no build)
   ├─ build/run  xcodebuild → simctl / devicectl;  watch → tier-1 rebuild+restore
   ├─ toolsets   stories · args · docs · test · actions · review
   └─ surfaces   MCP · CLI · Swift SDK · (later) Mac app · static HTML gallery
            │  WebSocket: typed invoke→ack→result + events
            │  sim: localhost · device: iproxy/LAN · fallback: launch args / openurl
 iOS simulator / device ──────────────────────────────────────────────────────
  Host app: (a) <App>Storybook target   or   (d) user's Debug build
   StorybookRuntime: registry (section records → conformance scan → register()
                     → optional #Preview import), StoryRenderer, services
                     (selection, args, globals, actions), agent server
   StorybookUI:      sidebar · canvas · Controls · Actions · a11y · Docs
   User modules:     components + *+Stories.swift (gated by #if STORYBOOK)
```

Proposed package products:
- `Storybook` (format; safe to link into component modules)
- `StorybookMacros`
- `StorybookRuntime`
- `StorybookUI`
- `StorybookTesting`
- `StorybookPreviewImport` (optional)
- the `storybook` CLI, shipped as an artifactbundle and through Homebrew

## Where the reports disagree

| Topic | Disagreement | Resolution |
| --- | --- | --- |
| `#Preview(arguments:)` and `PreviewProvider` deprecation | 01 marked them unverified; 04 stated them as fact | **Confirmed** in the Xcode 27.0 SDK. 01 and 02 now have notes. |
| Capture API | 04 suggests `ImageRenderer`; 03 warns against it | Use `drawHierarchy` / `UIGraphicsImageRenderer`. Keep `ImageRenderer` only for pure-SwiftUI token swatches. |
| In-app server | `NWListener` (03) vs FlyingFox (04) | Either works. Start with `NWListener`. |
| Macro name | `@Stories` on a type (02, 03) vs `@Story` (04) | `@Stories` on the type. A `#Story` freestanding form can come later. |
| Swift version | 6.3 (02, 03) vs 6.4 installed locally (04) | Section records need Swift 6.3 or later. The minimum toolchain is an open decision. |

## Decisions

Decided on 2026-10-17:

1. **Minimum toolchain and OS: Swift 6.3+, iOS 18+.**
   - The `@Stories` macro emits `@section` records, which are the primary
     discovery path. The conformance scan is the fallback for code that doesn't
     use the macro.
   - `traitOverrides` (iOS 17+) is always available.
   - `#Preview(arguments:)` import only works on iOS 26+ runtimes.
2. **Host target: a sidecar project.** `storybook init` generates a separate
   `Storybook.xcodeproj` or `Package.swift` app that references the user's
   packages. It never edits the user's `.pbxproj`.
3. **Device connection:**
   - **Simulator:** a localhost WebSocket.
   - **Physical devices:** the app shows its LAN address and a QR code, and
     the CLI connects over Wi-Fi.
   - No `iproxy` / libimobiledevice dependency.

4. **No dependency on SnapshotPreviews or Prefire. Import `#Preview`
   directly and use swift-snapshot-testing for snapshots.**
   - **Adoption is low.** As of 2026-10-17, public GitHub `Package.resolved` /
     `project.pbxproj` references were:
     - SnapshotPreviews: about 20 / 17;
     - Prefire: about 15 / 15;
     - swift-snapshot-testing: about 1,952 / 892.
   - **What matters is `#Preview` itself**, not the tools that harvest it.
     SnapshotPreviews' MIT discovery code is a reference for our importer, not
     a dependency.
   - **swift-snapshot-testing is the diff engine** behind `StorybookTesting`.
   - **The PNG + JSON sidecar export stays**, as a cheap way to feed Sentry
     Snapshots or reg-cli.

5. **Story files: support both locations, and default to next to the
   component.**
   - **Default:** templates and docs use a `Button+Stories.swift` file in the
     component's module, wrapped in `#if STORYBOOK`.
   - **Documented alternative:** a separate `ButtonStories` target that uses
     `@testable import`, for teams that want clean production modules.
   - **Discovery works the same either way**, because `importPath` is the
     `fileID`.

## Suggested first spike

> **Done.** The results are in [`../spike.md`](../spike.md).

This is the smallest end-to-end slice that tests the riskiest assumptions:

1. **`Storybook` core.** `Stories`, `StoryMeta`, `Story`, `StoryArgs`, and
   controls derived from args with `Mirror`. Start without the macro and list
   the stories by hand.
2. **`StorybookRuntime`.** A conformance scan for `Stories`, a `StoryRenderer`
   for SwiftUI, and a `NWListener` WebSocket with `listStories`, `renderStory`,
   `setArgs` and `snapshot`.
3. **A minimal `StorybookUI`.** A story list, a canvas and a generated Controls
   panel.
4. **A `storybook` CLI** with `render <id> --args '{…}' --out x.png` against a
   booted simulator, plus `storybook mcp` exposing the same tools.
5. **A sample design-system package** with three or four components, to test
   the experience.

**Then check:**
- `@section` records survive the configurations we care about;
- the static and runtime indexes agree;
- tier-1 rebuild-and-restore feels fast enough.
