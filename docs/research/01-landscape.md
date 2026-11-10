# 01 — Landscape: iOS design-system and component-catalog tooling

Research thread 1 of 4. This surveys what exists today for browsing, rendering
and testing iOS components in isolation, how each tool works, and where a
native iOS Storybook (see `../storybook-11-architecture-findings.md`) could fit.

> **As of 17 October 2026.** Star counts, release dates and last-push dates
> come from the GitHub API on that day. Claims about Apple's Xcode 27 betas
> come partly from third-party write-ups. Each one is marked where Apple's own
> docs didn't confirm it.

## TL;DR

- **`#Preview` is the de facto "story" format on iOS.** Xcode Previews are
  where every iOS developer already writes component states. Nearly every
  active third-party tool now *harvests* `#Preview`/`PreviewProvider` instead
  of asking for a new story format: SnapshotPreviews, Prefire, Phonebook,
  SwiftBook (2026), PreviewsMCP, and Xcode's own `RenderPreview` MCP tool. The
  older "write a separate scenario" libraries (Playbook, Storybook-SwiftUI)
  have stalled.
- **Apple moved into the agent space in 2026.** Xcode 26.3 (Feb 2026) exposes
  Xcode through MCP (`xcrun mcpbridge`), including **`RenderPreview`**, which
  returns a PNG of a preview. Xcode 27 reportedly adds a headless
  `xcrun mcp-server`, resizable previews, and previews for standalone `.swift`
  files. But Apple's surface is still **per-file and image-only**: no catalog,
  no args/controls, no component index, nothing that runs on a device for a
  designer.
- **The active third-party tools are snapshot-first.** SnapshotPreviews (now
  under Sentry, v0.20.0, 8 Oct 2026) and Prefire (v6.1.0, 12 Oct 2026) are
  healthy and release monthly. Both treat the in-app gallery as a by-product
  of snapshot testing, not as an interactive workbench.
- **Nobody ships interactive, typed controls (args) for native iOS
  components.** That is the core Storybook feature, and it's missing across the
  board. React Native Storybook has it on device, with WebSocket multi-device
  sync and an experimental MCP server, but there is no native equivalent.
- **Big design systems don't publish their iOS catalogs.** Airbnb, Uber,
  Shopify Polaris, Pinterest Gestalt, Spotify Encore, GitHub Primer and
  Atlassian have no public iOS component code or catalog tooling. Their public
  material is web or Figma. The public native design systems (Microsoft Fluent
  UI Apple, Skyscanner Backpack, Orange OUDS, Adevinta Spark, SBB) each ship a
  **hand-built demo app**, which is exactly the duplicated work a Storybook
  removes. Material Components iOS has been in maintenance mode since 2021 and
  is now archived.
- **The design-to-code bridges for iOS are weak.** Style Dictionary v5's
  built-in Swift formats still target UIKit. Figma Code Connect deprecated its
  framework parsers, SwiftUI's included, in v2 (Aug 2026), in favour of
  framework-agnostic templates. Figma's MCP server and its `figma-swiftui`
  skill generate SwiftUI, but nothing ties a Figma node, a token set, a story
  and a snapshot together.
- **Where to win:** a stable, machine-readable story index built from
  `#Preview` with an optional typed-args layer; on-device and Mac browsing with
  real controls; a catalog-level agent toolset (`listStories`, `render`,
  `setArgs`, `a11yTree`, `snapshot`) that works without Xcode open; and
  docs pages that link Figma, tokens and snapshots. Don't compete on snapshot
  diffing; interoperate with SnapshotPreviews and Prefire.

## 1. Apple: Xcode Previews

### 1.1 What exists

| Year / Xcode | Addition |
| --- | --- |
| 2019 / Xcode 11 | `PreviewProvider` protocol; canvas renders `static var previews`. Works for UIKit through `UIViewRepresentable` wrappers. |
| 2023 / Xcode 15 | **`#Preview` macro** (`#Preview("Title", traits: …) { … }`), first-class UIKit/AppKit previews (return a `UIView`/`UIViewController`), canvas **variants** (color scheme, orientation, Dynamic Type grids), `traits:` such as `.sizeThatFitsLayout`, `.fixedLayout(width:height:)`, `.landscapeLeft`. ([Swift with Majid](https://swiftwithmajid.com/2023/10/17/mastering-preview-macro-in-swift/), [WWDC23 10252](https://developer.apple.com/wwdc23/10252)) |
| 2024 / Xcode 16 | **`@Previewable`** (inline `@State` etc. in a preview body); **`PreviewModifier`** with a shared, cached `context` applied through custom `PreviewTrait`s (`#Preview(traits: .sampleData)`). New execution engine: Previews **share build products with the normal debug build** and "reassemble your program on the fly" instead of compiling a separate copy; the legacy dynamic-replacement engine is still behind "Use Legacy Previews Execution". ([WWDC24 10135](https://developer.apple.com/videos/play/wwdc2024/10135/), [Apple forums: build sharing](https://developer.apple.com/forums/thread/761439), [Apple forums: JIT errors](https://developer.apple.com/forums/thread/757676), [Swift with Majid](https://swiftwithmajid.com/2024/11/26/the-power-of-previews-in-xcode/)) |
| 2025 / Xcode 26 | **`#Playground` macro**: run code snippets inline in any Swift file and see results in the canvas. ([SwiftLee](https://www.avanderlee.com/swift/playground-macro-running-code-snippets-in-xcodes-canvas/)) |
| Feb 2026 / Xcode 26.3 | **Agentic coding + MCP.** Xcode exposes its tools over MCP via `xcrun mcpbridge` (Xcode must be running with the project open). Tools include `BuildProject`, `RunAllTests`, `RunSomeTests`, `DocumentationSearch`, `GetBuildLog`, and **`RenderPreview`**, which returns a PNG path (`previewSnapshotPath`) for a preview in a file, selected by index. ([Apple Newsroom](https://www.apple.com/newsroom/2026/02/xcode-26-point-3-unlocks-the-power-of-agentic-coding/), [pi-xcode-mcp README](https://cdn.jsdelivr.net/gh/igorkulman/pi-xcode-mcp@main/README.md), [Cursor Xcode docs](https://cursor.com/docs/integrations/xcode)) |
| WWDC26 / Xcode 27 | **Resize handles on live previews**, tied to resizable iPhone apps in iOS 27 and a resizable simulator; standalone `.swift` files open in their own window with previews and playground results; agents in editor panes with `/plan`; **Device Hub** for simulators and devices. ([What's new in Xcode 27](https://developer.apple.com/videos/play/wwdc2026/258/), [What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/), [Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2026/102/), [session digest](https://github.com/ivan-magda/wwdc26-notes/blob/main/sessions/258-xcode-27/digest.md)) |
| Xcode 27.0 (*verified in the local SDK, see note*) | **`#Preview(_:traits:arguments: [T]) { (T) -> View }`** (iOS 26+) and **`PreviewProvider` deprecated** ("Use #Preview instead."). Both were checked in the iOS 27.0 simulator SDK `swiftinterface`s (Xcode 27.0, 27A266a). |
| Xcode 27 beta 5 (*unverified*) | **Headless `xcrun mcp-server`**: runs `XcodeService.app` with no window, keeping `RenderPreview` and adding `DeviceInteraction*` tools that drive a simulator. One write-up says `RenderPreview` returns one PNG per state of a `#Preview(arguments:)` block; we found no Apple doc for an `arguments:` parameter. ([Mehmet Baykar, 8 Sep 2026](https://mehmetbaykar.com/posts/how-to-run-xcode-27-mcp-server-headless-with-claude-code/), [xcode-mods README](https://github.com/artemnovichkov/xcode-mods)) |

### 1.2 Strengths

- Zero adoption cost: the API is in every Xcode project, and developers
  already write previews.
- Fast iteration in the canvas, with good trait coverage (scheme, Dynamic Type,
  orientation, now resizing).
- `#Preview` is discoverable at runtime: the macro emits types that conform
  to a known protocol in the `__swift5_proto` Mach-O section, which is how
  SnapshotPreviews finds them without codegen (see §2.1).
- Since 2026, the first first-party agent hook: `RenderPreview`.

### 1.3 Weaknesses (well documented, and the opening for this project)

- **File-scoped.** The canvas shows the previews of one file. There's no
  cross-module catalog, search, tags or hierarchy, and nothing to hand a
  designer or PM.
- **Static.** No args or controls. Changing a prop means editing code.
  `@Previewable @State` gives local interactivity, not a control panel.
- **Xcode-only and opaque.** The preview agent is a private process. You can't
  run your own app setup (fonts, DI, Firebase) in it. PreviewsMCP's README
  calls this "the Xcode preview sandbox problem". Previews don't run on a
  TestFlight build.
- **Fragile.** Long-standing complaints about preview build failures, timeouts
  and engine quirks (e.g. static-library linking failures under the Xcode 16
  engine, JIT agent crashes in betas) ([Apple forums](https://developer.apple.com/forums/thread/757676), [Xcode Previews tag](https://developer.apple.com/forums/tags/xcode-previews)).
- **The agent surface is thin.** `RenderPreview` takes a file and an index and
  returns an image path. There's no story index, no args, no accessibility
  tree, and it times out on large projects (120 s MCP timeout noted by
  pi-xcode-mcp). Until the Xcode 27 headless service it also needed a GUI Xcode
  with the project open.

**Takeaway:** treat `#Preview` as the *input format* to support, not as a
competitor. The risk is Apple adding a catalog view to Xcode. Nothing at
WWDC26 points that way, but Apple is clearly investing in previews as an agent
surface, so build on top of that rather than on private preview internals.

## 2. Catalog, playground and preview-harvesting libraries

### 2.1 SnapshotPreviews and PreviewGallery (Emerge Tools, now Sentry)

- **Repo:** [getsentry/SnapshotPreviews](https://github.com/getsentry/SnapshotPreviews)
  (moved from `EmergeTools/SnapshotPreviews`). 630★, **v0.20.0 on 8 Oct 2026**,
  about monthly releases through 2026. Sentry acquired Emerge Tools in May 2025
  ([Sentry press release](https://sentry.io/about/press-releases/sentry-acquires-emerge-tools-to-enhance-its-mobile-app-monitoring-solution/)).
- **How it works:** at runtime it parses the `__swift5_proto` section of the
  binary to find `PreviewProvider` conformers and the types the `#Preview`
  macro generates. It then uses the Obj-C runtime to override XCTest's
  `testInvocations`, adding one test per preview. No codegen and no
  per-preview test code.
- **PreviewGallery:** a SwiftUI view that lists every discovered preview as a
  browsable gallery for internal builds. It needs the gallery linked, whole-
  module optimisation disabled so previews aren't stripped, and a compilation
  condition.
- **Extras:** `PreviewVariants` (dark, RTL, large text), per-preview modifiers
  (precision, tags, scroll expansion), `PreviewLayoutTest` (render without
  images), `AccessibilityPreviewTest` (Xcode accessibility audits per
  preview), and export of PNG + JSON sidecars for Sentry Snapshots or any
  differ. Supports iOS, macOS, watchOS, tvOS and visionOS, UIKit/AppKit/SwiftUI.
- **Good:** the best zero-effort discovery on the platform, multi-platform,
  well maintained, with a commercial owner.
- **Bad:** the gallery is a list of static renders with no args or controls.
  Its business model points at hosted snapshot diffing (Sentry), not at a
  workbench. No MCP or agent surface.

### 2.2 Prefire

- **Repo:** [BarredEwe/Prefire](https://github.com/BarredEwe/Prefire). 525★,
  **v6.1.0 on 12 Oct 2026**, releases every few weeks. v6.0.0 (8 Oct 2026)
  **replaced Sourcery with its own SwiftSyntax scanner**, added watchOS, and
  added iPhone 17 snapshot devices
  ([release](https://github.com/BarredEwe/Prefire/releases/tag/6.0.0)).
- **How it works:** a static scan of source files for `#Preview` and
  `PreviewProvider` (cached by mtime and SHA-256). It renders Stencil
  templates through SPM build-tool plugins (`PrefireTestsPlugin`,
  `PrefirePlaybookPlugin`), a CLI or Mint, and generates (a) snapshot tests on
  swift-snapshot-testing and (b) a **`PlaybookView`** catalog grouped by
  component or by `UserStory`/`State`. Opt in or out with `.prefireEnabled()`
  / `.prefireIgnored()`, tune with `.snapshot(delay:precision:)`.
- **Good:** compile-time manifest (deterministic, CI-friendly), active,
  practical config (`.prefire.yml`).
- **Bad:** codegen adds build plugins and generated files. The playbook is a
  basic list (`NavigationView` isn't supported in it). No controls, no agent
  surface.

### 2.3 Playbook (playbook-ui)

- **Repo:** [playbook-ui/playbook-ios](https://github.com/playbook-ui/playbook-ios).
  1,246★. **Last release 0.4.2 on 4 Dec 2024, no pushes since.** Stalled.
- **How it works:** "a library for isolated developing UI components",
  explicitly Storybook-inspired. You write `ScenarioProvider`s that register
  `Scenario`s (name, layout, closure that returns a view) into a `Playbook`.
  `PlaybookUI` is a browsing app with search. `PlaybookSnapshot` renders every
  scenario across devices from a unit test. There's also a Flutter port
  ([playbook-flutter](https://github.com/playbook-ui/playbook-flutter)).
- **Good:** the cleanest pre-SwiftUI-macros model of "story index + gallery +
  snapshots", and works for UIKit.
- **Bad:** a second story format next to previews. That's the reason
  `#Preview`-harvesting tools overtook it. No args or controls. Inactive.

### 2.4 "Storybook for iOS/SwiftUI" projects

| Project | Status (Oct 2026) | Approach | Notes |
| --- | --- | --- | --- |
| [aj-bartocci/Storybook-SwiftUI](https://github.com/aj-bartocci/Storybook-SwiftUI) | 43★, last push Jan 2026 | `@objc static var` entries on a `Storybook` class, found through the Obj-C runtime | v2 added a controls overlay (dark mode, font size, screen size), folders and tags; v2.1 added a Claude skill. The only iOS project we found with *any* control overlay, and it's global, not per-prop. |
| [golergka/viewcase](https://github.com/golergka/viewcase) | 0★, created Sep 2026 | Explicit `ViewcaseStory` array | Native macOS/iOS catalog with appearance, text size and canvas presets, state reset, offscreen PNG for agents/CI. |
| [brandonbloom/SwiftBook](https://github.com/brandonbloom/SwiftBook) | 0★, created Oct 2026, "preview release" | Runtime `#Preview` discovery | `#SwiftBookTests` snapshot-tests every preview in light/dark across Mac/iPhone/iPad/TV; a `swiftbook view` Mac viewer that redraws as code compiles. Needs macOS 27 / Xcode 27. |
| [hpennington/SwiftBook](https://github.com/hpennington/SwiftBook) | 21★, last push 2022 | Manual registration | Abandoned. |
| [stag-build/phonebook](https://github.com/stag-build/phonebook) | 11★, active (Oct 2026) | Harvests Compose `@Preview` (Roborazzi) and SwiftUI `#Preview` (SnapshotPreviews) into `manifest.json` + images, then a **static HTML gallery** | "MCP-first": an agent can check setup, analyse coverage, add missing previews and build the gallery. Self-hosted alternative to Emerge Snapshots. |
| [crleonard/UIAtlas](https://github.com/crleonard/UIAtlas) | 3★, Aug 2026 | Static HTML index over preview captures and swift-snapshot-testing references | Explicitly "not a live component workbench". |
| [storybookjs/native](https://github.com/storybookjs/native) | 220★, last push Apr 2024 | Web Storybook that embeds an Appetize.io streamed emulator, with deep links to pick a story | Inactive. Shows the "web manager + native preview" idea (option B in the architecture doc) and its friction: a cloud emulator, deep-link plumbing, limited controls. |

Plus smaller, older or doc-focused projects:
[doordash-oss/swiftui-preview-snapshots](https://github.com/doordash-oss/swiftui-preview-snapshots)
(197★, shares named configurations between previews and snapshot tests, last
push Jul 2024), [yyokii/UIPreviewCatalog](https://github.com/yyokii/UIPreviewCatalog)
(previews to Markdown, 2022), and [ipedro/swiftui-showcase](https://github.com/ipedro/swiftui-showcase)
(in-app docs templates, 8★).

### 2.5 Headless preview hosts and agent tooling (new in 2026)

- **PreviewsMCP** (originally `obj-p/PreviewsMCP`, installed with
  `brew tap obj-p/tap`; the original repo returned 404 on 17 Oct 2026, so we
  read it through forks such as [kezhuoquan/PreviewsMCP](https://github.com/kezhuoquan/PreviewsMCP)).
  It JIT-compiles a file's `#Preview` closure and links it into its own macOS
  `NSApplication` or iOS-simulator `UIApplication` host, with hot reload,
  trait sweeps (`colorScheme`, `dynamicTypeSize`, `locale`,
  `layoutDirection`), an **accessibility-tree dump and touch injection** on
  iOS, a background daemon, and a **setup plugin** (`setUp()` / `wrap()`) that
  solves the preview-sandbox problem. Works with SPM, Xcode projects and
  Bazel. Its README positions itself against Apple's `RenderPreview` as
  "tethered to a live GUI Xcode". This is the closest existing thing to the
  *preview runtime + toolset* half of this project, but it's file-scoped, with
  no catalog or args.
- **[k-kohey/axe](https://github.com/k-kohey/axe)** (96★, active): a CLI that
  runs SwiftUI previews with hot reload in a headless simulator, plus a VS Code
  extension.
- **[getsentry/MobileBuildMCP](https://github.com/getsentry/MobileBuildMCP)**
  (6.5k★; formerly XcodeBuildMCP): agent build, run and test over `xcodebuild`.
  No preview rendering.
- **[artemnovichkov/xcode-mods](https://github.com/artemnovichkov/xcode-mods)**
  (Oct 2026): shows `RenderPreview` output in a "Canvas" pane inside Claude
  Code. Evidence that people want a preview *viewer* next to the agent.

### 2.6 UIKit-era catalogs

Before previews, the norm was a hand-maintained "catalog" target. Apple's own
**UIKitCatalog** sample is the archetype. Material Components iOS shipped
a catalog app built from per-component example classes that declared their
own catalog metadata (menu path, primary-demo flag) and were collected into a
browsing UI (described from memory of the repo, not re-verified). MDC iOS entered maintenance mode on **15 July 2021** and the repo is now
**archived** (last release v124.2.0, Apr 2021)
([repo](https://github.com/material-components/material-components-ios),
[maintenance notice mirror](https://gitlink.org.cn/dnrops/material-components-ios)).
Airbnb's **Epoxy** ([airbnb/epoxy-ios](https://github.com/airbnb/epoxy-ios),
1.3k★, v0.11.0 Jun 2025, still pushed) ships an `EpoxyExample` app with a
catalog of examples. The pattern was always "registration metadata on example
classes plus a browsing app", which is what Playbook generalised.

### 2.7 Android comparison: Showkase and Compose previews

- **[airbnb/Showkase](https://github.com/airbnb/Showkase)** (2.3k★, v1.0.5 Aug
  2025, pushed Mar 2026): a KSP/annotation processor collects `@Preview` and
  `@ShowkaseComposable` composables, colors and typography into a generated
  **Showkase browser Activity**, grouped and searchable, with dark mode, RTL
  and font-scale toggles. It also exposes a generated list for screenshot tests
  (Paparazzi, Roborazzi). This is the model iOS lacks: *one annotation pass
  produces the browser, the token pages and the screenshot inputs*. The
  downside is codegen cost on every module.
- **Google's Compose Preview Screenshot Testing** (still experimental, AGP 9+)
  and **[ComposablePreviewScanner](https://central.sonatype.com/artifact/io.github.sergio-sastre.ComposablePreviewScanner/android)**
  (core of Roborazzi's preview support) bring "previews are tests" to Android
  ([Android docs](https://developer.android.com/studio/preview/compose-screenshot-testing)).
  iOS has the same split: Apple previews, plus third-party scanners that turn
  them into tests.

### 2.8 React Native Storybook: the on-device model

[storybookjs/react-native](https://github.com/storybookjs/react-native)
(1.3k★, **v10.7.0 on 13 Oct 2026**, `v11.0.0-next.0` the same day) is the only
mobile Storybook that is genuinely *on-device*:

- Real CSF stories, rendered inside the app, with an **on-device UI** (or a
  "lite" UI, or none).
- **On-device addons**: Controls, Actions, Backgrounds, Notes
  (`deviceAddons`).
- **WebSocket server** (`websockets: 'auto'`) to **sync several devices to the
  same story and args**, driven from the web UI or another device.
- **`experimental_mcp`**: an MCP server at `/mcp` on the channel server so
  agents can query docs and story metadata. It also ships agent skills.

**No native iOS equivalent exists.** Nobody offers typed per-prop controls,
an actions log, multi-device sync, or an MCP endpoint over a story index for
SwiftUI/UIKit. This is the clearest "port the idea" opportunity, and it lines
up with the toolset and delegated-mode ideas in the architecture doc.

## 3. How large design systems ship iOS components

Public evidence is thin. That is the main finding here: the big systems keep
their iOS implementations and catalog apps internal, and what they publish
(sites, Storybooks, Figma libraries) is web-first.

| Design system | Public iOS code? | Public catalog / tooling evidence |
| --- | --- | --- |
| **Airbnb DLS** | No DLS repo. Related OSS: Epoxy (UIKit), Lottie, HorizonCalendar, Swift style guide. | Airbnb wrote about rebuilding DLS components in SwiftUI with style protocols ([Unlocking SwiftUI at Airbnb](https://medium.com/airbnb-engineering/unlocking-swiftui-at-airbnb-ea58f50cde49); full text not retrievable for this survey). Showkase (Android) is Airbnb's public component browser. No iOS equivalent is open-sourced. |
| **Uber Base** | No. Uber's Swift OSS is architecture and tooling (RIBs-iOS, Needle, Mockolo). | Base Web (React) is public ([blog](https://www.uber.com/us/en/blog/introducing-base-web/)). "Design system at scale" reports adoption on Rider iOS (3× faster development, 50% less code vs custom components) but no tooling details ([blog](https://www.uber.com/au/en/blog/design-system-at-scale/)). |
| **Shopify Polaris** | No. `polaris-react` was archived and deprecated in favour of Polaris web components. Shopify's Swift OSS is commerce SDKs and Tophat. | Polaris is web/admin-focused. [Tophat](https://github.com/Shopify/tophat) (1.1k★) is adjacent: it installs PR builds to devices with one click, useful for reviewing native UI. |
| **Pinterest Gestalt** | No (only [pinterest/gestalt](https://github.com/pinterest/gestalt), React). | Gestalt says it partners with mobile teams on native components ([Design System Awards](https://zeroheight.com/events/design-system-awards/finalists/gestalt/)). Nothing public. |
| **Spotify Encore** | No. | Encore has had a mobile layer since 2019 and a dedicated mobile components group since 2022 ([designsystems.com](https://designsystems.com/how-spotifys-design-system-goes-beyond-platforms/), [Figma blog](https://www.figma.com/blog/creating-coherence-how-spotifys-design-system-goes-beyond-platforms/)). No catalog tooling disclosed. |
| **GitHub Primer** | No public Swift repos in the `primer` org. | Primer's public tooling is web Storybook and Figma ([a11y annotations post](https://github.blog/engineering/user-experience/design-system-annotations-part-1-how-accessibility-gets-left-out-of-components/)). |
| **Atlassian** | No. | atlassian.design is web components only. Mobile is React Native and native inside each product app. |
| **Material Components iOS** | Yes, **archived** (maintenance since Jul 2021). | Catalog app (see §2.6). Google now recommends HIG + UIKit/SwiftUI. |
| **Microsoft Fluent UI Apple** | Yes: [microsoft/fluentui-apple](https://github.com/microsoft/fluentui-apple), 977★, v0.37.0 Aug 2026. | Hand-built `Demos` apps (iOS and macOS). |
| **Skyscanner Backpack** | Yes: [Skyscanner/backpack-ios](https://github.com/Skyscanner/backpack-ios), v93.3.1 15 Oct 2026, UIKit + `Backpack-SwiftUI` + `Backpack-Tokens`. | Hand-built `Example` app plus a `screenshots` pipeline for docs. |
| **Orange OUDS** | Yes: [Orange-OpenSource/ouds-ios](https://github.com/Orange-OpenSource/ouds-ios), v3.1.0 Oct 2026 (its predecessor ODS iOS is archived). | A separate showcase app repo, [ouds-ios-design-system-toolbox](https://github.com/Orange-OpenSource/ouds-ios-design-system-toolbox), plus DocC docs. |
| **Adevinta Spark** | Yes: [adevinta/spark-ios](https://github.com/adevinta/spark-ios), v2.2.0 Oct 2026. | A `Demo` app in the repo, with Sourcery codegen. |
| **Kiwi.com Orbit** | [kiwicom/orbit-swiftui](https://github.com/kiwicom/orbit-swiftui), **archived** May 2025. | A storybook-style catalog app in the repo. |
| **SBB (Swiss railways)** | Yes: [mobile-ios-design-swiftui](https://github.com/SchweizerischeBundesbahnen/mobile-ios-design-swiftui), 88★, active. | Demo app. |

**Patterns:**

1. Every public native design system maintains a **bespoke demo app**,
   sometimes in a separate repo (Orange). That's duplicated effort, it drifts
   from the components, and it has no shared conventions for controls or
   variants.
2. Tokens are a first-class package (Backpack-Tokens, OUDS tokens), usually
   generated from a Figma/JSON source.
3. Screenshots for docs are generated by snapshot pipelines, not taken by hand.
4. Two notable iOS design systems (MDC, Kiwi Orbit) were archived in the
   survey window. Bespoke catalog infrastructure is a maintenance burden that
   a shared tool could take on.

## 4. Design-token and Figma bridges

### 4.1 Style Dictionary

- [style-dictionary/style-dictionary](https://github.com/style-dictionary/style-dictionary):
  4.9k★, **v5.7.0 on 16 Oct 2026**, very active. v5.0.0 (May 2025) adopted the
  **DTCG 2025.10** spec as its base format
  ([zeroheight note](https://help.zeroheight.com/hc/en-us/articles/48049028236187)).
- iOS output: built-in `ios-swift/class.swift`, `ios-swift/enum.swift` and
  `ios-swift/any.swift` formats (plus Obj-C `ios/*`). By default they **import
  `UIKit`** and emit `UIColor`/`CGFloat`-style values
  ([predefined formats](https://github.com/style-dictionary/style-dictionary/blob/main/docs/src/content/docs/reference/Hooks/Formats/predefined.md)).
  There's no built-in SwiftUI `Color`/`Font` output or asset-catalog
  (`.colorset`) output, so teams write custom formats.

### 4.2 Tokens Studio

- Figma plugin. Its export needs
  [`@tokens-studio/sd-transforms`](https://github.com/tokens-studio/sd-transforms)
  (v2.0.3, Dec 2025) before Style Dictionary
  ([docs](https://docs.tokens.studio/transform-tokens/style-dictionary)). No
  first-party Swift guidance; teams use Style Dictionary's `ios-swift`
  formats.

### 4.3 Figma Code Connect

- [figma/code-connect](https://github.com/figma/code-connect): 1.6k★,
  **v2.0.2 on 14 Oct 2026**. It shows real component snippets in Dev Mode
  instead of auto-generated code. Organization/Enterprise plans only.
- **v2.0.0 (18 Aug 2026) deprecated framework-specific parsers, SwiftUI's
  included.** They now only run under `figma connect migrate`/`unpublish`, and
  **template files** are "the only actively maintained way"
  ([release](https://github.com/figma/code-connect/releases/tag/v2.0.0),
  [migration guide](https://developers.figma.com/docs/code-connect/templates-migration-guide/)).
  The old SwiftUI path used a Swift package and `figma-swift` CLI to map Figma
  props and variants to Swift initialisers
  ([SwiftUI docs](https://www.figma.com/code-connect-docs/swiftui)).
- Implication: the mapping from a Figma component to a SwiftUI component and
  its props is now hand-written template metadata. A story manifest that
  already knows a component's props and variants could **generate Code Connect
  templates**.

### 4.4 Figma Dev Mode and the Figma MCP server

- Dev Mode inspects specs and shows Code Connect snippets. The Figma MCP
  server's `get_code` defaults to React + Tailwind but can be prompted for
  SwiftUI. Figma publishes a **`figma-swiftui` skill** (design to SwiftUI, and
  SwiftUI views or tokens back to Figma), first seen Jun 2026
  ([skills.sh](https://www.skills.sh/figma/dev-mode-mcp-server-guide/figma-swiftui),
  [Figma MCP guide](https://docsearch.algolia.com/mcp/docs/repo/figma/mcp-server-guide)).
  Xcode MCP-client support is reported but we didn't confirm it from a primary
  source ([createwith](https://www.createwith.com/tool/figma/updates/figma-mcp-server-now-supports-xcode-for-native-apple-development)).
- The emerging agent loop: Figma MCP → generate SwiftUI → Xcode
  `RenderPreview` → compare. It works at screen level, but **has no component
  catalog in the middle** to tell the agent "this design is `DSButton(.primary,
  size: .large)`; render that story with these args."

## 5. Comparison table

★ = GitHub stars and dates as of 17 Oct 2026. "Discovery" is how the tool
finds stories.

| Tool | Platform | Discovery | Browse UI | Args / controls | Snapshots | Agent / MCP | Runs outside Xcode | Maintained |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Xcode Previews | iOS/macOS/etc. | `#Preview` in the open file | Xcode canvas, per file | No (`@Previewable` only) | Via `RenderPreview` | `RenderPreview` (26.3+), headless server (27 β, unverified) | No | Apple |
| SnapshotPreviews / PreviewGallery | All Apple | Runtime `__swift5_proto` scan | In-app gallery (static) | No (variants only) | Yes, PNG+JSON, a11y audits | No | Yes (in app) | ✅ v0.20.0, Oct 2026 |
| Prefire | iOS/tvOS/macOS/watchOS | SwiftSyntax scan + codegen | `PlaybookView` (static) | No | Yes (swift-snapshot-testing) | No | Yes (in app) | ✅ v6.1.0, Oct 2026 |
| Playbook | iOS (UIKit/SwiftUI) | Manual `ScenarioProvider` | PlaybookUI app | No | Yes | No | Yes | ❌ last Dec 2024 |
| Storybook-SwiftUI (aj-bartocci) | iOS/macOS | Obj-C runtime on `@objc` vars | In-app | Global overlay only | No | Claude skill | Yes | ⚠️ last Jan 2026 |
| Viewcase | iOS/macOS | Manual array | In-app, native | Global (appearance, text, canvas) | Offscreen PNG | PNG for agents | Yes | 🆕 Sep 2026 |
| SwiftBook (brandonbloom) | Mac/iOS/iPad/TV | Runtime `#Preview` | Mac viewer, live redraw | No | Yes, perceptual diff | No | Yes | 🆕 preview, Oct 2026 |
| PreviewsMCP | macOS / iOS sim | Per-file `#Preview`, JIT | Live window | Trait sweeps | Yes | ✅ MCP + CLI, a11y tree, touch | Yes (headless) | ⚠️ origin repo 404, forks |
| Phonebook | iOS + Android | Via SnapshotPreviews / Roborazzi | Static HTML | No | Harvested | ✅ MCP (setup, coverage) | CI | 🆕 Oct 2026 |
| storybookjs/native | iOS/Android/Flutter | Web CSF + deep links | Web + Appetize | Limited | No | No | Cloud emulator | ❌ last Apr 2024 |
| **RN Storybook** (reference) | React Native | CSF | On-device + web | ✅ Full controls, actions | Via addons | ✅ `experimental_mcp` | Yes | ✅ v10.7.0, Oct 2026 |
| **Showkase** (reference) | Android | KSP annotations | Generated Activity | Global toggles | Via Paparazzi etc. | No | Yes | ⚠️ v1.0.5, Aug 2025 |
| Bespoke DS demo apps | iOS | Hand-written | Custom | Ad hoc | Separate | No | Yes | Per team |

## 6. Gaps: what nobody does well today

1. **Typed, per-prop controls for native components.** No iOS tool lets you
   change `title`, `style`, `isLoading` or `size` of a SwiftUI/UIKit component
   at runtime from a generated panel. RN Storybook proves the demand, and the
   existing iOS overlays only cover global environment toggles.
2. **A stable, cross-module story index.** Every tool rebuilds one privately:
   Prefire's generated Swift, SnapshotPreviews' runtime scan, Phonebook's
   `manifest.json`, PreviewsMCP's per-file parse. There's no shared,
   documented manifest (ids, titles, hierarchy, tags, args schema, source
   location, Figma link) that tools and agents can rely on, and nothing like
   Storybook's `index.json`.
3. **A catalog-level agent toolset.** Xcode's `RenderPreview` and PreviewsMCP
   are *file-level renderers*. Nobody offers `listStories(tag:)`,
   `getStory(id)` (props schema + docs), `render(id, args, traits)`,
   `setArgs`, `getA11yTree`, or `snapshot(all, variants)` over a whole design
   system, with attach-or-launch behaviour, on device or in the simulator.
4. **One artifact for developers, designers and agents.** In practice the
   options are the Xcode canvas (developers only), a bespoke demo app
   (drifts), or a static HTML gallery (no interaction). Nothing shares one
   source across in-app browsing on TestFlight, a Mac host, CI snapshots and
   MCP.
5. **Escaping the preview sandbox, safely.** Teams need app-level setup
   (fonts, DI, feature flags, mock networking) around every story. PreviewsMCP's
   `setUp()`/`wrap()` and Xcode 16's `PreviewModifier` hint at the answer, but
   no catalog tool treats **decorators/globals** as a first-class, composable
   concept.
6. **Docs pages.** No iOS tool generates a component page with usage, a props
   table (from SwiftSyntax/docgen), every story, tokens used, accessibility
   notes and a Figma link. Teams use DocC (Orange) or nothing.
7. **Design-to-code linkage.** With Code Connect SwiftUI parsers deprecated and
   Style Dictionary's Swift output UIKit-first, nobody connects *Figma
   component ↔ story/args ↔ tokens ↔ snapshot*.
8. **Multi-device sync and review.** Showing the same story with the same args
   on an iPhone, an iPad and the Mac at once (RN Storybook's WebSocket mode)
   has no native equivalent. Neither does a designer flipping controls on a
   phone while the developer watches.
9. **Interaction and behaviour tests.** Snapshot tools cover the look. Nobody
   offers Storybook-style **play functions** (scripted interactions plus
   assertions) for native components outside full XCUITest flows.

## 7. Recommendations for this project

These map onto the open questions in
`../storybook-11-architecture-findings.md` §5.

1. **Story source: support both, `#Preview` first.** Index every
   `#Preview`/`PreviewProvider` with zero adoption cost. Use static SwiftSyntax
   scanning (like Prefire v6) for the build-time manifest, and the runtime
   `__swift5_proto` lookup (like SnapshotPreviews) for in-app discovery. Add an
   **opt-in typed `Story` layer** (macro or protocol) for args/controls,
   decorators and docs metadata. Upgrading a preview to a story should be a
   one-line change, not a rewrite. The Playbook lesson: don't *require* a
   second story format.
2. **Make the manifest the product.** Publish a documented, versioned story
   index (JSON), shaped close to Storybook's `index.json` (id, title, name,
   tags, importPath equivalent) plus native fields (module, source location,
   args schema from `Codable` + control metadata, traits, Figma URL). This is
   the gap every tool works around. Emit it at build time (CLI/SPM plugin) and
   at runtime.
3. **Lead with controls.** Typed args with generated control panels in the
   in-app browser and the Mac host are the feature nobody has. Start small:
   `Bool`, `String`, number ranges, `CaseIterable` enums, colors. Expand later.
4. **Ship a catalog-level toolset over MCP + CLI + Swift API** (the toolset
   pattern from the architecture doc): `stories.list/get`, `render` (with
   args + traits → PNG), `args.set`, `a11y.tree`, `snapshot.batch`, `docs.get`.
   Use delegated mode: attach to a running simulator or device app, otherwise
   launch one. Position it as **complementary to Xcode's `RenderPreview`**:
   Xcode renders a file, we answer "what components exist and how do I render
   this one with these props."
5. **Run in our own host process, not Apple's preview agent.** Like
   PreviewsMCP and PreviewGallery, render inside an app we control (simulator,
   device, Mac Catalyst/macOS host), so decorators can run real setup. Avoid
   private Xcode preview internals; they change every year.
6. **Interoperate on snapshots instead of competing.** Export stories with
   their variants in a form SnapshotPreviews, Prefire or swift-snapshot-testing
   can consume (or accept their outputs), and leave hosted diffing to
   Sentry and others. Our job is the index, the workbench and the agent
   surface.
7. **Decorators = `PreviewModifier`-compatible.** Model globals and decorators
   (color scheme, Dynamic Type, locale, layout direction, device, theme) so an
   existing `PreviewModifier`/`PreviewTrait` can be reused as a decorator.
   That's a cheap migration path.
8. **Design-system hooks from day one, cheaply.** Optional `figma:` URL and
   `tokens:` references on stories. A tokens panel that reads DTCG JSON (Style
   Dictionary v5's input format). Later, **generate Code Connect template
   files** from the manifest. Those three features cover gap 7 without building
   a token pipeline.
9. **Multi-device sync as a phase-2 feature.** One authority (Mac host) with
   leaves (devices) gives RN Storybook-style sync. That matches the "start with
   one authority and patches" advice in the architecture doc.
10. **Target the people who build bespoke demo apps.** Fluent UI Apple,
    Backpack, OUDS, Spark and SBB all maintain hand-written catalogs. A
    migration guide ("replace your Demo app with ten lines of setup") and one
    of them as a showcase adopter would be strong validation.
11. **Watch list:** Xcode 27's headless MCP server and any `#Preview`
    parameterisation (it could change how args map to previews);
    SnapshotPreviews and Sentry's direction; PreviewsMCP's status (its origin
    repo has gone missing); Phonebook (closest in "MCP-first gallery" spirit);
    RN Storybook v11 (likely to follow Storybook 11 toolsets, worth aligning
    tool names with).

## Sources

Apple:
[Xcode 26.3 newsroom](https://www.apple.com/newsroom/2026/02/xcode-26-point-3-unlocks-the-power-of-agentic-coding/) ·
[WWDC26 What's new in Xcode 27](https://developer.apple.com/videos/play/wwdc2026/258/) ·
[WWDC26 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/) ·
[WWDC26 Platforms SOTU](https://developer.apple.com/videos/play/wwdc2026/102/) ·
[WWDC24 10135 previews](https://developer.apple.com/videos/play/wwdc2024/10135/) ·
[WWDC23 10252](https://developer.apple.com/wwdc23/10252) ·
[Adding previews to interface files](https://developer.apple.com/documentation/xcode/adding-previews-to-your-interface-files) ·
[Forums: Xcode 16 build sharing](https://developer.apple.com/forums/thread/761439) ·
[Forums: JIT errors](https://developer.apple.com/forums/thread/757676) ·
[Xcode 27 notes digest](https://github.com/ivan-magda/wwdc26-notes/blob/main/sessions/258-xcode-27/digest.md) ·
[Headless mcp-server write-up](https://mehmetbaykar.com/posts/how-to-run-xcode-27-mcp-server-headless-with-claude-code/) ·
[pi-xcode-mcp](https://cdn.jsdelivr.net/gh/igorkulman/pi-xcode-mcp@main/README.md) ·
[Cursor Xcode integration](https://cursor.com/docs/integrations/xcode) ·
[SwiftLee #Playground](https://www.avanderlee.com/swift/playground-macro-running-code-snippets-in-xcodes-canvas/) ·
[Swift with Majid: #Preview](https://swiftwithmajid.com/2023/10/17/mastering-preview-macro-in-swift/) ·
[Swift with Majid: previews 2024](https://swiftwithmajid.com/2024/11/26/the-power-of-previews-in-xcode/)

Libraries and tools:
[SnapshotPreviews](https://github.com/getsentry/SnapshotPreviews) ·
[Sentry acquires Emerge](https://sentry.io/about/press-releases/sentry-acquires-emerge-tools-to-enhance-its-mobile-app-monitoring-solution/) ·
[Prefire](https://github.com/BarredEwe/Prefire) ·
[Playbook](https://github.com/playbook-ui/playbook-ios) ·
[Storybook-SwiftUI](https://github.com/aj-bartocci/Storybook-SwiftUI) ·
[Viewcase](https://github.com/golergka/viewcase) ·
[SwiftBook (brandonbloom)](https://github.com/brandonbloom/SwiftBook) ·
[Phonebook](https://github.com/stag-build/phonebook) ·
[UIAtlas](https://github.com/crleonard/UIAtlas) ·
[storybookjs/native](https://github.com/storybookjs/native) ·
[PreviewsMCP (fork)](https://github.com/kezhuoquan/PreviewsMCP) ·
[axe](https://github.com/k-kohey/axe) ·
[MobileBuildMCP](https://github.com/getsentry/MobileBuildMCP) ·
[xcode-mods](https://github.com/artemnovichkov/xcode-mods) ·
[swiftui-preview-snapshots](https://github.com/doordash-oss/swiftui-preview-snapshots) ·
[swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) ·
[Epoxy](https://github.com/airbnb/epoxy-ios) ·
[Material Components iOS](https://github.com/material-components/material-components-ios) ·
[Showkase](https://github.com/airbnb/Showkase) ·
[Compose Preview Screenshot Testing](https://developer.android.com/studio/preview/compose-screenshot-testing) ·
[React Native Storybook](https://github.com/storybookjs/react-native)

Design systems:
[Unlocking SwiftUI at Airbnb](https://medium.com/airbnb-engineering/unlocking-swiftui-at-airbnb-ea58f50cde49) ·
[Uber Base Web](https://www.uber.com/us/en/blog/introducing-base-web/) ·
[Uber design system at scale](https://www.uber.com/au/en/blog/design-system-at-scale/) ·
[Spotify Encore (designsystems.com)](https://designsystems.com/how-spotifys-design-system-goes-beyond-platforms/) ·
[Spotify Encore (Figma)](https://www.figma.com/blog/creating-coherence-how-spotifys-design-system-goes-beyond-platforms/) ·
[Gestalt awards page](https://zeroheight.com/events/design-system-awards/finalists/gestalt/) ·
[Primer a11y annotations](https://github.blog/engineering/user-experience/design-system-annotations-part-1-how-accessibility-gets-left-out-of-components/) ·
[Atlassian DS](https://atlassian.design/get-started/about-atlassian-design-system) ·
[Fluent UI Apple](https://github.com/microsoft/fluentui-apple) ·
[Backpack iOS](https://github.com/Skyscanner/backpack-ios) ·
[OUDS iOS](https://github.com/Orange-OpenSource/ouds-ios) ·
[OUDS toolbox](https://github.com/Orange-OpenSource/ouds-ios-design-system-toolbox) ·
[Spark iOS](https://github.com/adevinta/spark-ios) ·
[Orbit SwiftUI](https://github.com/kiwicom/orbit-swiftui) ·
[SBB iOS design](https://github.com/SchweizerischeBundesbahnen/mobile-ios-design-swiftui) ·
[Tophat](https://github.com/Shopify/tophat)

Tokens and Figma:
[Style Dictionary](https://github.com/style-dictionary/style-dictionary) ·
[SD predefined formats](https://github.com/style-dictionary/style-dictionary/blob/main/docs/src/content/docs/reference/Hooks/Formats/predefined.md) ·
[zeroheight SD v5 / DTCG](https://help.zeroheight.com/hc/en-us/articles/48049028236187) ·
[Tokens Studio + SD](https://docs.tokens.studio/transform-tokens/style-dictionary) ·
[sd-transforms](https://github.com/tokens-studio/sd-transforms) ·
[Code Connect](https://github.com/figma/code-connect) ·
[Code Connect v2.0.0](https://github.com/figma/code-connect/releases/tag/v2.0.0) ·
[Templates migration guide](https://developers.figma.com/docs/code-connect/templates-migration-guide/) ·
[Code Connect SwiftUI docs](https://www.figma.com/code-connect-docs/swiftui) ·
[figma-swiftui skill](https://www.skills.sh/figma/dev-mode-mcp-server-guide/figma-swiftui) ·
[Figma MCP guide](https://docsearch.algolia.com/mcp/docs/repo/figma/mcp-server-guide)
