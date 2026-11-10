# 04 · Supporting tooling: the addons and integrations around the catalog

This document is research thread 4 of 4. It covers the tooling a serious native iOS Storybook needs **around** the catalog itself: the iOS equivalents of Storybook's addons and integrations. Read it with `../storybook-11-architecture-findings.md`.

> **As of 2026-10-17.**
> - **How the facts were gathered:**
>   - GitHub metadata (latest release, last push, archive status, license) was pulled live with `gh api`.
>   - Some API details were checked against the locally installed **Xcode 27.0 (27A266a), Swift 6.4**. Those are marked **[local]** and have no URL.
>   - Anything that could only be found in secondary sources, or not confirmed at all, is marked **UNVERIFIED**.
> - **Baseline:** Xcode 27 shipped 2026-09-14 and Swift 6.4 shipped 2026-09-15. "Xcode 26" is now last year's release.

## TL;DR

- **Xcode 27 changed the landscape this year. Three changes matter most:**
  1. **`#Preview(_:traits:arguments:body:)`** with `PreviewArguments<T>` is Apple's version of Storybook args. The canvas shows a grid with one preview per argument.
  2. Xcode 27 **deprecates `PreviewProvider`**.
  3. Xcode is now an **MCP server**:
     - `xcrun mcpbridge` arrived in 26.3.
     - Xcode 27 added a headless `xcrun mcp-server` preview.
     - Its `RenderPreview` / "Preview Snapshot" tool renders `#Preview` variants (appearance, orientation, type size).
     - Its agent tools boot simulators, synthesize touches and take screenshots.

  **Implication:** we should build on `#Preview` as a story source and integrate with Xcode's MCP. We should not try to compete with it.
- **Snapshot testing is solved. Integrate it rather than building it.**
  - **swift-snapshot-testing** (1.19.6, very active, supports Swift Testing and attachments) is the diff engine.
  - **SnapshotPreviews** (now under getsentry, v0.20.0) and **Prefire** (6.1.0) already turn `#Preview`s into snapshot tests. Both are also the closest prior art for the whole project.
  - **The interop format is "a directory of PNGs plus a JSON sidecar per story."** Sentry Snapshots, reg-suit/reg-cli and Happo's API all accept it.
- **"Stories as tests" maps onto a parameterized Swift Testing test**, `@Test(arguments: StoryIndex.all)`, with image attachments. In web Storybook the archived test-runner gave way to the Vitest addon; this is the native counterpart.
  - **Play functions:**
    - ViewInspector for fast, in-process interactions.
    - XCUITest for real event synthesis. It is still XCTest-only; Swift Testing can't host UI tests.
    - AXe, idb or the Xcode 27 agent tools for agent-driven steps.
- **Accessibility:**
  - **Automated checks:** `performAccessibilityAudit` runs once per story in a UI-test bundle. It has had no new audit types since 2022 [local].
  - **VoiceOver:** **AccessibilitySnapshot** (cashapp, 0.13.1, active) is the best on-device VoiceOver panel.
  - **Other settings:** decorators handle Dynamic Type, Bold Text and color scheme through the environment. Contrast and Reduce Motion only have underscore-prefixed (undocumented) setters.
  - **Dead options:** GTXiLib and A11yUITests are archived.
- **Controls, Actions and Docs: no native prior art has live arg editing.**
  - **What to copy:** React Native Storybook's on-device addons and WebSocket channel are the model.
  - **Docgen:** a SwiftSyntax scan for argTypes plus symbol graphs for doc comments, merged into a component manifest. DocC handles long-form docs, and its 6.3+ experimental Markdown output suits agents.
- **Figma: Code Connect 2.0 (2026-08-18) deprecated the SwiftUI parser.** Only `.figma.ts` templates are maintained now. We should generate templates from the story index, and read tokens as **DTCG 2025.10** through **Style Dictionary 5** or **Terrazzo** into `.xcassets`.
- **Agent surface: the field is crowded.**
  - **What exists:**
    - MobileBuildMCP (renamed from XcodeBuildMCP after Sentry acquired it)
    - Callstack's agent-device
    - mobile-mcp
    - Appium MCP
    - Maestro MCP
    - Xcode's own MCP server
  - **What to build:** only what's unique to us, which is story-aware toolsets (`stories`, `docs`, `test`, `review`, plus `args`).
    - Define each tool once.
    - Copy Storybook 10.6's `defineToolset` shape and tool names.
    - Relay to an in-app WebSocket/HTTP server. FlyingFox or Hummingbird can provide it.
- **CI and distribution:**
  - **CI:** GitHub `macos-26` arm64 runners are GA, with Xcode 27 in public preview.
  - **Sharing:** Tuist Previews or TestFlight for builds, Appetize for deep-linked web streaming, and reg-cli HTML galleries for snapshots.
  - **Shipping the tool:** an SPM package plus an `.artifactbundle` and a signed Homebrew tap. **No CocoaPods**: trunk goes read-only on 2026-12-02.

---

## 1. Visual and snapshot testing

### 1.1 Libraries

| Library | What it is | Latest / status (Oct 2026) | License | Catalog fit |
|---|---|---|---|---|
| [pointfreeco/swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) | Strategy-based `assertSnapshot(of:as:)` for images, text and dumps; inline snapshots | **1.19.6 (2026-09-21)**, active, ~4.4k★ | MIT | The diff engine |
| [getsentry/SnapshotPreviews](https://github.com/getsentry/SnapshotPreviews) (formerly EmergeTools) | Turns every `#Preview` into an XCTest snapshot with no test code; in-app `PreviewGallery`; a11y audit test | **v0.20.0 (2026-10-08)**, active, ~630★ | MIT | Closest prior art; its discovery technique and sidecar schema are worth copying |
| [BarredEwe/Prefire](https://github.com/BarredEwe/Prefire) | Parses `#Preview`/`@Previewable` with SwiftSyntax; generates snapshot tests, a Playbook catalog view and "flows" | **6.1.0 (2026-10-12)**, very active, ~525★ | Apache-2.0 | Proves build-time preview→index→codegen works |
| [cashapp/AccessibilitySnapshot](https://github.com/cashapp/AccessibilitySnapshot) | Snapshots of the VoiceOver hierarchy (overlay plus legend) | **0.13.1 (2026-09-17)**, active | Apache-2.0 | Ready-made a11y addon (§3) |
| [uber/ios-snapshot-test-case](https://github.com/uber/ios-snapshot-test-case) | Objective-C FBSnapshotTestCase successor | Last release 8.0.0 (2021-10-22); dormant | MIT | Legacy only; skip |
| [playbook-ui/playbook-ios](https://github.com/playbook-ui/playbook-ios) | Storybook-style `Scenario`s, catalog app, auto snapshots | 0.4.2 (2024-12-04); **dormant** | Apache-2.0 | API reference, not a dependency |

**swift-snapshot-testing details:**
- **Swift Testing support:**
  - Beta support since 1.17.0 (2024-07-08).
  - Suite-level config uses the trait `@Suite(.snapshots(record: .failed))`.
  - **Swift Testing attachments** and an explicit `record:` parameter landed in 1.19.0 (2026-03-18).
- **Record modes:** `.all`, `.failed`, `.missing` and `.never`. Set them with the `SNAPSHOT_TESTING_RECORD` env var.
- **2.0 is not scheduled.** A community 2.0 PR was declined; the maintainers say "We have our own ideas and timeline" ([PR #1003](https://github.com/pointfreeco/swift-snapshot-testing/pull/1003)).

**SnapshotPreviews details:**
- **How it finds previews:** it scans the `__swift5_proto` Mach-O section for preview types and injects test invocations at runtime.
- **What it writes:** PNGs plus JSON sidecars (`display_name`, `group`, `diff_threshold`, `tags`, `context`).
- **Caveat:** its README warns that whole-module optimization strips preview metadata in release-like builds.
- **Framework:** XCTest-based; the README doesn't mention Swift Testing.

**Apple:**
- No `#Preview`→XCTest snapshot API exists.
- Apple's preview rendering is available only through the Xcode MCP tools (§7.2).

### 1.2 Hosted visual-regression services

| Service | Native iOS? | Ingestion | Pricing / status |
|---|---|---|---|
| **Sentry Snapshots** (formerly Emerge) | Yes, from any tool | Upload a PNG directory plus optional JSON sidecars with `sentry-cli`¹ or the Fastlane `sentry_upload_snapshots` action. Sentry diffs against the base build, shows a review UI and posts GitHub checks. | **Open beta** since 2026-06-15 ([changelog](https://sentry.io/changelog/snapshots-is-now-in-open-beta), [docs](https://docs.sentry.io/platforms/apple/snapshots/)); pricing not published |
| Emerge Snapshots (legacy) | Yes | Upload an XCArchive; previews are rendered on the server | Docs still up ([docs](https://docs.emergetools.com/docs/ios-snapshots)); Sentry is the evident successor (end-of-life date UNVERIFIED) |
| **Chromatic** | **React Native only** (early access) | Builds the RN Storybook app and drives it over WebSockets on hosted simulators ([docs](https://www.chromatic.com/docs/react-native)) | Free 5k snapshots/mo; $179 / $399 / Enterprise ([pricing](https://www.chromatic.com/pricing)) |
| **BrowserStack App Percy** | Yes (XCUITest/Appium) | Screenshots captured in device-cloud sessions ([site](https://www.browserstack.com/app-percy)) | Free 1k screenshots/mo; paid tiers UNVERIFIED |
| **Applitools Eyes XCUI** | Yes | `eyes.check()` inside XCUITests; EyesXCUI 10.5.0 (2026-08-17) ([changelog](https://applitools.com/tutorials/sdks/xcui/changelog)) | Sales-quoted |
| **Happo** | Claimed "via the Happo API"; no native docs found | API upload | Free 5k; from $149/mo ([pricing](https://happo.io/pricing)) |
| **Sherlo** | RN Storybook only | Cloud simulators, Figma side-by-side ([repo](https://github.com/sherlo-io/sherlo)) | Free plan |
| **Lost Pixel** | No | — | **Sunsetting**; team joined Figma 2026-04-22 ([blog](https://lost-pixel.com/blog/lost-pixel-team-is-joining-figma)) |
| **reg-suit / reg-cli** (OSS) | Any image directory | `compare` produces a static HTML diff report; S3/GCS publishing; GitHub notifications ([reg-suit](https://github.com/reg-viz/reg-suit), [reg-cli](https://github.com/reg-viz/reg-cli)) | Free, MIT. reg-cli 0.19.0-rc3 (2026-09-24) rewrote its diff engine in Rust→WASM |

¹ The two research sources disagree on the subcommand spelling: `sentry-cli snapshots upload` versus `sentry-cli build snapshots` (sentry-cli 3.4.0+). Check [the upload docs](https://docs.sentry.io/product/snapshots/uploading-snapshots/) before relying on either.

**Design implication:** produce **one artefact**, `snapshots/<storyId>/<variant>.png` plus `<variant>.json` with fields compatible with SnapshotPreviews' sidecar. Sentry, reg-cli and Happo all take that directly. Percy and Applitools require capture inside an XCUITest session, so they are an optional adapter, not the core path.

### 1.3 Mapping "stories as tests" from web Storybook

| Storybook (web 10.6 / 11-alpha) | Status | Native iOS equivalent |
|---|---|---|
| Portable stories: `composeStories`, `story.run()` runs loaders and the play function ([docs](https://storybook.js.org/docs/api/portable-stories/portable-stories-vitest)) | Current | A `Story` value that can render itself outside the catalog: `story.makeView(args:)` plus `story.play(_:)` |
| `@storybook/addon-vitest`: each story is a test (smoke render, play, a11y); sidebar status ([docs](https://storybook.js.org/docs/writing-tests/integrations/vitest-addon)) | Current, Vite only, no snapshots | A **parameterized Swift Testing test** over the story index. Every argument case is a story×variant: render, attach the PNG, run play steps, run the a11y check. Xcode 27 adds per-argument test links and faster large parameterized suites ([Xcode 27 notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)). |
| `@storybook/test-runner` (Jest + Playwright against `index.json`) | **Archived**; support ended ([repo](https://github.com/storybookjs/test-runner)) | An XCUITest bundle that launches the catalog once and deep-links to each story. Use it only for things that need out-of-process checks. |
| Chromatic (stories as visual tests, TurboSnap) | Current | The PNG directory goes to Sentry or reg-cli. "Changed stories only" comes from our own module/file→story map (`stories.changed`). |
| Per-story test status in the sidebar | Current | Read results back from `.xcresult` with `xcresulttool get test-results` [local], or from Swift Testing's JSON event stream ([ST-0002 et al.](https://github.com/swiftlang/swift-evolution/tree/main/proposals/testing)). Show them as status badges in the catalog and through `test.run`. |

**React Native Storybook is the closest analog.** It is at v10.7.0, with v11.0.0-next.0 out on 2026-10-13 adding CSF Factories ([releases](https://github.com/storybookjs/react-native/releases)). Its [testing docs](https://storybookjs.github.io/react-native/docs/intro/testing) recommend:
- Jest portable stories.
- **Maestro flows generated from the story index.** Each flow deep-links to a story, asserts it is visible and takes a screenshot, then compares with `looks-same`.

Play functions running on device are *not* documented there.

## 2. Interaction tests (play functions)

| Option | How it drives | Latest / status | Strengths | Weaknesses |
|---|---|---|---|---|
| [nalexn/ViewInspector](https://github.com/nalexn/ViewInspector) | In-process traversal of the SwiftUI view tree, e.g. `button.tap()` | **0.10.5 (2026-09-30)**; iOS 26.4 fixes; iOS 27 work in progress; MIT, ~2.6k★ | Fast and deterministic. Since 0.10.3 it **no longer depends on XCTest**, so it can run inside the catalog app. | Depends on SwiftUI internals and breaks with each OS release; no real hit-testing or gestures |
| **XCUITest** | Out-of-process, real event synthesis | Xcode 26 added recording, replay and review ([WWDC25-344](https://developer.apple.com/videos/play/wwdc2025/344/)). Xcode 27 adds **`XCUIVoiceOverService`** and a crash-severity setting in test plans ([notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)). | Apple-supported; Percy and Applitools hook in here | **XCTest only.** Swift Testing can't host UI tests as of Xcode 27 (inferred from release notes). Slow launch, which we work around with one launch plus deep links. |
| **Swift Testing** ([repo](https://github.com/swiftlang/swift-testing), 6.4.1) | Test host, not a driver | Attachments (ST-0009, Xcode 26). **Image attachments** for `UIImage`/`CGImage` (Xcode 26.4). Parameterized tests, cancellation, tag filtering. | The right home for per-story smoke tests, snapshots and ViewInspector play steps | No UI testing; exit tests aren't available on iOS (third-party source; check ST-0008) |
| **AXe** ([repo](https://github.com/cameroncooke/AXe), v1.8.0) / **idb** ([repo](https://github.com/facebook/idb), v1.7.6, revived Aug 2026) | Accessibility-tree plus HID input from the host | Active; AXe supports Xcode 27 Device Hub | No test bundle needed; ideal for MCP and agent-authored steps | Simulator only; needs good accessibility-identifier hygiene |
| Xcode 27 agent tools | Touch synthesis plus screenshots through Xcode MCP | New in 27 | First-party | Needs Xcode running and user consent; tool names still settling (§7.2) |

**Recommendation:**
- Write play functions in a **small Swift DSL** (`tap("Submit")`, `type("email", "a@b.c")`, `expect(label: "Done")`) that resolves targets by accessibility identifier or label.
- The DSL runs in two places:
  - **In-process**, inside the catalog (an accessibility-element walker, with ViewInspector as an optional backend). This gives instant "Interactions" panel feedback and Swift Testing runs.
  - **Translated to XCUITest or AXe steps** when real gestures matter.
- The DSL serializes to JSON, so agents can author play steps as data through MCP. The JSON form is our own design suggestion, not prior art.

## 3. Accessibility

### 3.1 Automated audits
- **`XCUIApplication.performAccessibilityAudit(for:_:)`** (iOS 17+) ([Apple](https://developer.apple.com/documentation/xctest/xcuiapplication/4191487-performaccessibilityaudit), [WWDC23-10035](https://developer.apple.com/videos/play/wwdc2023/10035/)):
  - **Audit types** [local, Xcode 27 header]: `contrast`, `elementDetection`, `hitRegion`, `sufficientElementDescription`; on iOS also `dynamicType`, `textClipped` and `trait`. No new types since 2022.
  - **Issue fields:** `element`, `compactDescription`, `detailedDescription`, `auditType`. They map cleanly onto JSON.
  - **Scope:** it audits the **current view** only. Inferred from the API's wording: off-screen elements are probably skipped.
  - **Prior art:** SnapshotPreviews' `AccessibilityPreviewTest` already runs it for every `#Preview`.
- **Accessibility Inspector** has **no CLI** [local]. It is a manual tool; don't depend on it.
- **SwiftLint 0.65.1** ([releases](https://github.com/realm/SwiftLint/releases)) has opt-in rules `accessibility_label_for_image` and `accessibility_trait_for_button`. No maintained, dedicated SwiftUI a11y linter exists.
- **Deque axe DevTools Mobile (`axeDevToolsXCUI`)**:
  - Release 4.3.0 on 2026-10-07; commercial ([repo](https://github.com/dequelabs/axe-devtools-ios)).
  - About 30 WCAG-mapped rules.
  - Its Dynamic Type rule is now built on Apple's audit API.
  - Fit: an optional paid backend.
- **Archived, so don't adopt:** [google/GTXiLib](https://github.com/google/GTXiLib) (archived 2026-04-17) and [rwapp/A11yUITests](https://github.com/rwapp/A11yUITests) (archived 2025-12-31; recommends AccessibilitySnapshot).

### 3.2 Settings as decorators/globals
**SwiftUI environment** (the Xcode 27 interface) [local]:
- **Public setters:** `dynamicTypeSize`, `legibilityWeight` (Bold Text), `colorScheme`, `layoutDirection`, `locale`.
- **Underscore-prefixed public setters only** (undocumented, could change): `colorSchemeContrast`, `accessibilityReduceMotion`, `accessibilityReduceTransparency`, `accessibilityDifferentiateWithoutColor`, `accessibilityInvertColors`, `accessibilityShowButtonShapes`.
- **Get-only:** `accessibilityVoiceOverEnabled`, `accessibilitySwitchControlEnabled` and others.

**UIKit stories** don't see environment overrides. Use `overrideUserInterfaceStyle` and trait overrides instead.

**System level**, for full-app or out-of-process runs [local]:
- `xcrun simctl ui <dev> appearance | increase_contrast | content_size`. There are only these three; no Reduce Motion, Bold Text or VoiceOver.
- Xcode 27's `xcrun devicectl device settings appearance` adds `--text-size`, `--increase-contrast`, `--reduce-motion`, `--reduce-transparency`, `--show-borders` and more, plus a `voiceover --enable|--disable` toggle. This targets physical devices; whether it works on simulators is UNVERIFIED.

### 3.3 VoiceOver
- The Simulator has no VoiceOver ([forums](https://developer.apple.com/forums/thread/716937)).
- **What we can automate:**
  - **AccessibilitySnapshot**:
    - `AccessibilitySnapshotParser` and the new portable `AccessibilitySnapshotModel` (0.12.0) give a VoiceOver reading order as data, ideal for an MCP `a11y.voiceOver` tool and an in-app panel.
    - `AccessibilitySnapshotPreviews` (0.11.0) is a toggleable overlay.
  - Xcode 27's `XCUIVoiceOverService`, in UI tests.
- **Color contrast:** use the `.contrast` audit. A WCAG luminance-ratio helper is small enough to write ourselves for token stories.

## 4. Controls and Actions panels

**Prior art, none of which has proper live arg editing:**

| Project | Controls? | Status |
|---|---|---|
| Xcode Previews | `#Preview(arguments:)` gives a static grid; there's no interactive props panel. `PreviewModifier` (iOS 18+) is Apple's decorator. | Xcode 27 |
| [Prefire](https://github.com/BarredEwe/Prefire) | Generated PlaybookView; expands preview arguments | Active |
| [SnapshotPreviews `PreviewGallery`](https://github.com/getsentry/SnapshotPreviews) | Browser only | Active |
| [aj-bartocci/Storybook-SwiftUI](https://github.com/aj-bartocci/Storybook-SwiftUI) | Overlay with dark mode, font, screen size and custom controls | 2.1.1 (2026-01-29), 43★ |
| [playbook-ios](https://github.com/playbook-ui/playbook-ios) | None | Dormant |
| [airbnb/Showkase](https://github.com/airbnb/Showkase) (Android) | Automatic permutations only | 1.0.5 (2025-08) |
| **[storybookjs/react-native](https://github.com/storybookjs/react-native)** | `addon-ondevice-controls` (13 control types), `-actions`, `-backgrounds`, `-notes`. A **`websockets` server syncs story and arg state across devices**; `experimental_mcp` serves `/mcp` on the same server ([addons](https://storybookjs.github.io/react-native/docs/intro/addons/)) | v10.7.0, the model to copy |

**Design:**
- **Controls:**
  - Derive them from typed `Codable` args plus control metadata (§5's manifest supplies defaults and types).
  - Render them natively in the catalog's panel.
  - Mirror state over the channel, so `args.set` from the CLI or MCP and the on-device panel stay in sync. This is exactly the RN Storybook pattern.
- **Actions:**
  - Provide an `action("onTap")` helper that returns a closure of the right type.
  - The closure records `{storyId, name, args, timestamp}` to an Actions service, which shows it in the panel and streams it over the channel.
  - Optionally mirror actions to `os_log`; [OSLogStore](https://developer.apple.com/documentation/oslog/oslogstore) `.currentProcessIdentifier` can read them back.
- **Hot reload:** Apple has no official hot reload as of Xcode 27. Recommend [Inject](https://github.com/krzysztofzablocki/Inject) (1.6.0) or [InjectionNext](https://github.com/johnno1962/InjectionNext) (2.0.2RC3) as optional, rather than building our own.
- **Inspector addons**, both optional: [FLEX](https://github.com/FLEXTOOL/FLEX) (commits through 2026 but no release since 2022) and [Pulse](https://github.com/kean/Pulse) (5.2.3) for networking. Hyperion-iOS is gone (404).

## 5. Docs and docgen

**Storybook's model:**
- `reactDocgen` extracts props.
- `features.componentsManifest` builds a manifest that the MCP `docs-*` tools serve ([features](https://storybook.js.org/docs/api/main-config/main-config-features)).

**Native equivalent, layered:**
1. **SwiftSyntax** (604.0.0, 2026-09-15; [repo](https://github.com/swiftlang/swift-syntax)) does argTypes extraction. It reads init parameters, defaults, `@Binding`/`@State`, and `#Preview(arguments:)`. Prefire 6.0 and SwiftLint work this way.
2. **Symbol graphs** (`swift-symbolgraph-extract` / `-emit-symbol-graph`, decoded with [SymbolKit](https://github.com/swiftlang/swift-docc-symbolkit)) provide doc comments, declarations and relationships. They don't carry defaults or property-wrapper semantics in structured form.
3. Merge both into a **component manifest JSON** keyed by component, listing its stories. This is the `docs` toolset's data source and the catalog's Docs tab.
4. **[Swift-DocC](https://github.com/swiftlang/swift-docc)** (6.4.0) handles long-form guides and can host articles.
   - Swift 6.3 added experimental **Markdown output** (good for agents) and **static per-page HTML** ([Swift 6.3 blog](https://swift.org/blog/swift-6.3-released/)).
   - [swift-docc-plugin](https://github.com/swiftlang/swift-docc-plugin) 1.5.0 adds `@Snippet` and more.
   - **Optional:** a DocC directive or snippet that embeds story snapshots.

**Other tools:**
- [SourceKitten](https://github.com/jpsim/SourceKitten) 0.39.0 is active but redundant with SwiftSyntax.
- jazzy 0.15.5 is maintained, but this is likely its last release with CocoaPods support.
- swift-doc is **archived**.
- Sourcery 2.3.0 (2025-09) is slow-moving. Prefire dropped it for SwiftSyntax.

**Discovery without codegen:**
- Swift Testing registers `@Test` records in a `__swift5_tests` section ([discussion](https://forums.swift.org/t/how-does-swift-testing-test-discovery-work/72771)).
- SE-0492 `@section`/`@used` ([proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md), implemented in Swift 6.3) makes the same trick available to a `@Story` macro.

## 6. Design tokens and Figma

- **Figma Code Connect** ([repo](https://github.com/figma/code-connect), MIT, Org/Enterprise plans only):
  - Current release **v2.0.2 (2026-10-14)**.
  - **2.0.0 (2026-08-18) deprecated the framework-specific parsers, SwiftUI included.** "Template files are now the only actively maintained way of using Code Connect" ([release](https://github.com/figma/code-connect/releases/tag/v2.0.0), [migration guide](https://developers.figma.com/docs/code-connect/templates-migration-guide/)).
  - The old `FigmaConnect` Swift DSL (`@FigmaEnum`, etc.) works only if you pin `@figma/code-connect@1`.
  - **Plan:** generate `.figma.ts` templates from our manifest (component, args mapped to Figma properties, a code snippet) and publish them with `figma connect`. Don't adopt the Swift DSL.
- **[Figma MCP server](https://developers.figma.com/docs/figma-mcp-server/)** (remote `mcp.figma.com/mcp` or desktop):
  - `get_variable_defs` reads tokens without needing the Enterprise Variables API.
  - `get_screenshot` gives a "design vs. implementation" panel.
  - `add_code_connect_map` lets agents link stories to Figma nodes.
  - Xcode is a listed client ([tools](https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/)).
- **Variables REST API:** still Enterprise-only (third-party source, July 2026; UNVERIFIED against official docs). Figma's native DTCG variable export (around Dec 2025) has reported format bugs.
- **Token format:** **[DTCG 2025.10](https://www.w3.org/community/reports/design-tokens/CG-FINAL-format-20251028/)**, the first stable version (2025-10-28), with theming, P3/Oklch and aliases.
- **Pipelines into Swift:**
  - [Style Dictionary](https://styledictionary.com/reference/hooks/formats/predefined/) **5.7.0** (2026-10-16): `ios-swift/class.swift`, `enum.swift` and `any.swift`. It has no `.colorset` format, so that needs a custom format.
  - [Terrazzo](https://terrazzo.app/docs/integrations/swift/) CLI 2.9.0 with `@terrazzo/plugin-swift` 0.3.4 emits **`.xcassets`** from DTCG. It is marked experimental. Cobalt UI is superseded.
  - [Tokens Studio](https://tokens.studio/pricing) plugin 2.13.0: exporting DTCG JSON is a Pro feature.
  - Xcode generates `ColorResource`/`ImageResource` symbols from asset catalogs. This replaces **SwiftGen**, which has had no release since 6.6.3 (2024-03-02) and is effectively unmaintained.
- **Vendors:**
  - [Supernova](https://www.supernova.io/for-ai) (active, has an MCP server) and [zeroheight](https://zeroheight.com/) (MCP) are possible publish targets later.
  - **Specify has shut down.**
  - Knapsack has pivoted away from design-system docs.
- **Storybook analogs:**
  - [`@storybook/addon-designs`](https://storybook.js.org/docs/sharing/design-integrations) 11.1.4 adds a Figma embed panel.
  - Storybook Connect embeds stories in Figma, but needs Chromatic.
  - **Native version:** a per-story `figmaURL` parameter that shows a Figma screenshot (via MCP or REST) next to the render. The reverse direction, Figma linking to our story, needs a hosted gallery URL (§8.2).

**Catalog features:** token stories (color, typography and spacing swatches) generated from the asset catalog or DTCG JSON, plus per-story Figma links.

## 7. Agent and automation surface

### 7.1 Existing iOS MCP servers and drivers

| Project | Owner / runtime | Latest | Notes |
|---|---|---|---|
| [getsentry/MobileBuildMCP](https://github.com/getsentry/MobileBuildMCP) (formerly **XcodeBuildMCP**) | Sentry (acquired 2026-02-11, [blog](https://blog.sentry.io/sentry-acquires-xcodebuildmcp)); TS/Node; MIT; ~6.5k★ | v2.7.1 (2026-09-23, rename) | Covers build, test, `screenshot`, `snapshot_ui`, `tap`, `set_sim_appearance`, `record_sim_video` and debugging. Bundles AXe. Has an `xcode_ide_call_tool` passthrough to `xcrun mcpbridge`. **Tools are defined as YAML manifests** that drive both MCP and CLI. Telemetry is on by default. |
| [callstack/agent-device](https://github.com/callstack/agent-device) (moved from callstackincubator) | Callstack; TS/Node 22; MIT; ~5k★ | v0.21.28 (2026-10-15) | **CLI, MCP and Node SDK on one runtime**, the same shape we want. Accessibility snapshot refs (`@e2`), press/fill with settle diffs, replay scripts, Maestro export. |
| [mobile-next/mobile-mcp](https://github.com/mobile-next/mobile-mcp) | TS; Apache-2.0; ~9.7k★ | 1.0.11 (2026-10-14) | Accessibility tree first, coordinates as fallback; simulators via mobilecli |
| [joshuayoes/ios-simulator-mcp](https://github.com/joshuayoes/ios-simulator-mcp) | JS; MIT | v2.1.0 (2026-08-13) | Built on idb; `ui_describe_all`, `ui_tap`, `screenshot`, `record_video` |
| [appium/appium-mcp](https://github.com/appium/appium-mcp) | TS; Apache-2.0 | v1.97.1 (2026-10-12) | WebDriverAgent; works on physical devices |
| [Maestro MCP](https://docs.maestro.dev/get-started/maestro-mcp) | Kotlin; Apache-2.0 | cli-2.11.0 | `inspect_screen`, `run` YAML flows, cloud |
| [Expo MCP](https://docs.expo.dev/eas/ai/mcp) | Hosted | — | Prior art for in-app tools that address views by testID |
| [callstackincubator/simlock](https://github.com/callstackincubator/simlock) | TS; MIT | new | Leases simulators to parallel agents |
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | Swift | v0.12.1 (2026-05-07) | For a Swift-native MCP server |

### 7.2 Apple's own

**Xcode 26.3** ([setup docs](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)):
- **Setup:** `xcrun mcpbridge` (server name `xcode-tools`). Turn it on in Settings › Intelligence; the project must be open in Xcode, and Xcode shows a consent alert.
- **Tools:** about 20, including `RenderPreview`, `BuildProject`, `RunSomeTests`, `DocumentationSearch` and `ExecuteSnippet`. **`RenderPreview` parameter names are UNVERIFIED** (reports conflict).

**Xcode 27** ([notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)):
- **Preview Snapshot / RenderPreview:**
  - Renders light/dark, orientation and type-size variants, plus preview groups.
  - Returns device, OS, display name and line number.
- **Agent tools:** boot simulators, install and launch apps, synthesize touches, take screenshots.
- **Other additions:** `lldb-mcp`, ACP support, agent plug-ins.
- **Headless `sudo xcrun mcp-server enable` (Beta 5 preview):** has an `--unsafe-always-allow-all-agents` option for CI.
- **Tool count:** a blog reports 48 tools ([Reda Lemeden](https://redalemeden.com/derived-data/2026/what-new-in-xcode-27-mcp-bridge/)); the exact names are UNVERIFIED.

**Implication:**
- Apple renders `#Preview`s from **source files**. It does not know about stories, args, decorators, play functions or a story index, and it needs Xcode running (headless mode is still a preview).
- Our tools should add the story layer and **pass through** to Xcode where it helps, as MobileBuildMCP does.

### 7.3 Low-level primitives (verified locally on Xcode 27)

- **`xcrun simctl`:**
  - Capture: `io screenshot`, `io recordVideo`.
  - Settings: `ui appearance | increase_contrast | content_size`, `status_bar override`.
  - App control: `openurl` (deep links), `launch` (env via `SIMCTL_CHILD_*`), `privacy`, `push`, `location`.
  - **No tap and no accessibility tree.**
- **`xcrun devicectl`** for physical devices: `device process launch`, `settings appearance`, `voiceover`, `capture screenshot`/`screen-record` (seen in `--help` only), and `--json-output -`.
- **Taps:** AXe or idb on simulators; XCTest/WebDriverAgent or the Xcode 27 agent tools on devices.

### 7.4 Storybook's agent surface (the template)

Storybook 10.6 is the template ([MCP overview](https://storybook.js.org/docs/ai/mcp/overview), [toolset definition](https://github.com/storybookjs/storybook/blob/next/code/core/src/shared/open-service/README.md), [CLI/SDK](https://github.com/storybookjs/storybook/blob/next/code/core/src/cli/tools/README.md)):
- **Tool names:** `docs-list`, `docs-show`, `docs-show-story`, `stories-preview`, `stories-changed`, `stories-find-by-component`, `review-create`, and `test-run` (from addon-vitest, includes a11y).
  - The older `list-all-documentation` / `get-documentation` names are legacy.
  - [storybookjs/mcp](https://github.com/storybookjs/mcp) is archived and merged into core.
- **`defineToolset({id, methods})`:**
  - Methods take a **strict** input schema and an optional output schema.
  - `handler(input, ctx)` returns `{ok, data, markdown}`, which maps to `structuredContent`, text and `isError`/exit code.
  - **Throw** when the method couldn't do the job; return **`ok:false`** when the answer is bad news.
- **Naming:** names are derived per transport: `stories.findByComponent` becomes MCP `stories-find-by-component` and CLI `stories find-by-component`.
- **Gotchas from the 11.0 alpha:**
  - Include an `instructions` field in structured output, because Claude Code passes the model only `structuredContent`.
  - Keep descriptions under 2048 characters.
- **Attached mode:** the CLI and SDK find running instances through `~/.storybook/instances/*.json`.
- **[RN Storybook MCP](https://github.com/storybookjs/react-native/blob/next/docs/docs/intro/configuration/mcp-configuration.md):**
  - Served at `:7007/mcp`.
  - **`select-story`** relays `setCurrentStory` over WebSocket to the device. This is the closest prior art for a host-side MCP server driving an on-device runtime.

### 7.5 Proposed toolsets

Define each tool once, then derive MCP, CLI (`isb …`) and the Swift SDK from that definition.

| Toolset | Methods | Implementation |
|---|---|---|
| `stories` | `list`, `findByComponent`, `changed`, `select`, `render` | `render({storyId, args?, variant:{colorScheme, dynamicType, contrast, layoutDirection, locale, device, orientation}})` returns a PNG plus metadata. It renders in-process with `ImageRenderer` / `UIGraphicsImageRenderer` for component images, and falls back to `simctl io screenshot` for full-screen evidence. |
| `args` | `get`, `set`, `reset` | Channel commands to the running app; re-render with no rebuild |
| `docs` | `list`, `show`, `showStory` | The component manifest from §5 |
| `test` | `run` (smoke, snapshot diff, play, a11y), `a11y.audit`, `a11y.voiceOver` | Runs the parameterized Swift Testing suite or the UI-test bundle, then parses `.xcresult`. Returns `instructions` so the agent can loop until clean, Storybook's "self-healing loop". |
| `actions` | `list`, `clear` | Reads the Actions service log |
| `review` | `create({title, description, collections[{title, rationale, storyIds}], changedFiles})` | **Copy Storybook's schema exactly.** Publishes a static gallery page (§8.2). |

**Transport, best option first:**
1. **The app hosts a server on localhost; the host process is the MCP server and relays to it.**
   - This works because the simulator shares the Mac's network stack.
   - The port and token come in through `SIMCTL_CHILD_*` env vars.
   - The app writes an instance record, like Storybook's `instances/*.json`.
   - Server options:
     - [FlyingFox](https://github.com/swhitty/FlyingFox): MIT, async/await, WebSockets, 0.27.1. **Smallest footprint.**
     - [Hummingbird](https://github.com/hummingbird-project/hummingbird): Apache-2.0, NIO, 2.28.0.
     - Avoid Telegraph, Swifter and GCDWebServer: they are stale or archived.
2. **Deep links** (`simctl openurl isb://story/<id>?args=…`) as a fallback for `select`. One-way only.
3. **Bonjour (`NWListener`)** for physical devices. Needs the local-network Info.plist keys (UNVERIFIED specifics).
4. **Delegate taps and gestures** to agent-device, AXe or MobileBuildMCP rather than building our own driver.

## 8. CI and distribution

### 8.1 Headless CI

- **[GitHub Actions](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/):**
  - `macos-26` arm64 is GA, and `macos-latest` points to it.
  - The image has Xcode 26.0.1–26.6 (26.6 default) and iOS 26.x runtimes.
  - **Xcode 27 is a public preview** (`xcode-27` labels) ([image readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)).
  - macOS 14 images are unsupported from 2026-11-02.
- **Other hosts:**
  - [Xcode Cloud](https://developer.apple.com/xcode-cloud/get-started): 25 hours/month free.
  - [Bitrise](https://bitrise.io/platform/build-platform/apple-silicon): M4/M4 Pro machines. Xcode 27 stack UNVERIFIED.
  - [CircleCI](https://support.circleci.com/hc/en-us/articles/360047734172-Building-Apple-Silicon-Apps-on-CircleCI): `m4pro.*` machines.
  - [Codemagic](https://docs.codemagic.io/specs-macos/xcode-27-0.md): Xcode 27 edge image, and a built-in Appetize integration.
- **Cirrus Labs joined OpenAI** (2026-04-07). Cirrus CI was scheduled to shut down on 2026-06-01, and **Tart** now lives at [openai/tart](https://github.com/openai/tart) (FSL license). It's fine for self-hosting, but not something to depend on.
- **[Tuist](https://tuist.dev/en/docs/guides/features/selective-testing)** (4.212.0):
  - Selective testing and the binary cache need Tuist-generated projects.
  - The Xcode compilation cache works with any project.
- **Snapshot determinism:**
  - swift-snapshot-testing's README says snapshots must be compared on the exact same simulator that recorded them.
  - Known drift sources:
    - Intel vs Apple silicon, for gradients, blur and shadows ([Paramount](https://paramount.tech/blog/2025/01/24/snapshot-tests-precision.html), [Apple forums](https://developer.apple.com/forums/thread/734704)).
    - Metal-rendered blur.
    - Probably Liquid Glass, since it relies on blur (UNVERIFIED).
  - **Mitigations:**
    - Pin Xcode, the runtime and the device.
    - Record on CI, on a single arm64 image.
    - Use `perceptualPrecision` around 0.98.
    - Write runtime and device into each sidecar.
    - Offer a "freeze animations" decorator (SnapshotPreviews 0.19.0 already freezes spinners and ProgressView).
- **Extracting results:**
  - `xcrun xcresulttool export attachments --path X.xcresult --output-path out --only-failures` writes the attachments plus a `manifest.json` [local].
  - [xcparse](https://github.com/ChargePoint/xcparse) has been stale since 2024; skip it.

### 8.2 Sharing with designers

| Channel | Fit | Notes |
|---|---|---|
| **Static HTML gallery** (our build + [reg-cli](https://github.com/reg-viz/reg-cli)) | **Best default.** No install; linkable per story and variant; doubles as the `review.create` output and the Figma back-link | PNG directory, then an HTML index plus diff report, then GitHub Pages or S3 |
| **[Tuist Previews](https://tuist.dev/en/docs/guides/features/previews)** | Simulator or device builds per PR; `tuist run <url>`; QR code; works with plain Xcode projects via `tuist xcodebuild` | Org members only by default; pricing UNVERIFIED |
| **[TestFlight](https://developer.apple.com/testflight/)** | Real devices; 100 internal testers (no review) or 10k external | 90-day expiry; first external build needs review; can be enabled for Apple silicon Macs |
| **[Appetize.io](https://docs.appetize.io/platform/query-params-reference)** | **Live catalog in the browser.** `launchUrl=isb://story/<id>` plus `params={args}` deep-links each story; the JS SDK can tap and screenshot | Simulator `.app` zip only. Free tier (30 min/mo); Starter $59/mo annual ([pricing](https://appetize.io/pricing)) |
| [Sentry Build Distribution](https://docs.sentry.io/platforms/apple/guides/ios/build-distribution) | XCArchive upload, install groups | Early adopter |
| Firebase App Distribution, Diawi, [Runway](https://docs.runway.team/using-runway/build-distro) | Ad hoc / UDID-based | Device-limit friction |
| Mac Catalyst build | Designers run it on a Mac; can be Developer ID-signed and notarized | Requires the catalog to support Catalyst; "Designed for iPad" is effectively TestFlight or App Store only |

### 8.3 Distributing the tool itself

- **SPM is the primary channel:**
  - Library products: `StorybookCore`, `StorybookUI`, `StorybookTesting`.
  - An optional **macro product** kept separate, because macros pull in swift-syntax.
  - Swift 6.4's SwiftPM defaults to **prebuilt swift-syntax** for macros [local], which only applies when using `swiftlang/swift-syntax` versions that have prebuilts ([forum](https://forums.swift.org/t/preview-swift-syntax-prebuilts-for-macros/80202)). Whether the Xcode IDE uses prebuilts by default is UNVERIFIED.
- **SPM plugins:**
  - **Build-tool plugins** suit index generation. They are sandboxed with no network, and Xcode makes users "Trust & Enable" them; CI needs `-skipPackagePluginValidation`.
  - A **command plugin** (`swift package isb …`) can write to the package with `--allow-writing-to-package-directory` ([SE-0332](https://github.com/apple/swift-evolution/blob/main/proposals/0332-swiftpm-command-plugins.md)).
- **The CLI binary:**
  - Publish a **`.artifactbundle.zip`** on GitHub releases. One artefact serves [mise `spm:`](https://mise.jdx.dev/dev-tools/backends/spm.html), [nest](https://github.com/mtj0928/nest) and SPM binary targets for plugins.
  - Also publish a **signed, notarized Homebrew tap**. [Homebrew 5.0](https://brew.sh/2025/11/12/homebrew-5.0.0) deprecated unsigned casks.
  - [Mint](https://github.com/yonaskolb/Mint) (0.18.0, builds from source, low activity) is optional.
- **Not worth it:**
  - Xcode Source Editor Extensions: text buffer only ([XcodeKit](https://developer.apple.com/documentation/xcodekit)).
  - **CocoaPods:** trunk goes **read-only on 2026-12-02** ([blog](https://blog.cocoapods.org/CocoaPods-Specs-Repo/)).
- **Better IDE integration:**
  - Ship an **Xcode 27 agent plug-in** (bundling skills plus our MCP server).
  - Ship a **Tuist plugin/recipe**.

---

## Prioritised plan for an MVP

### Build (what's unique to us)
1. **Story index plus component manifest.** Use SwiftSyntax, seeded from `#Preview` and `#Preview(arguments:)` and optionally a `@Story` macro, merged with symbol-graph doc comments. Everything else depends on this.
2. **The channel and toolset layer.**
   - An in-app FlyingFox WebSocket server plus a host CLI/MCP relay.
   - Copy Storybook's `defineToolset` shape and tool names (`stories-*`, `docs-*`, `test-run`, `review-create`), and add `args-*`.
   - Include an attached-mode instance file.
3. **Native Controls and Actions panels** on top of typed args and an `action(_:)` closure helper, synced over the channel. React Native Storybook is the model.
4. **Decorators/globals for environment variants.** Cover color scheme, Dynamic Type, Bold Text, layout direction and locale, plus contrast and Reduce Motion through the underscore setters (feature-flagged, since they're undocumented).
5. **`StorybookTesting`.** A parameterized Swift Testing suite over the index (smoke render, attach PNG, optional play steps) that emits the **PNG plus JSON sidecar directory**.
6. **Static HTML gallery generator.** It serves as the review page, the designer share link and the target for Figma back-links.

### Integrate (adopt, wrap or interoperate)
1. **swift-snapshot-testing** as the diff engine (record modes, `perceptualPrecision`).
2. **AccessibilitySnapshot:**
   - Its Parser/Model powers the VoiceOver panel and the `a11y.voiceOver` tool.
   - `performAccessibilityAudit` runs per story in an optional UI-test bundle.
3. **Sentry Snapshots** and **reg-cli** as consumers of our PNG directory. Document the recipes; build no code.
4. **Xcode MCP passthrough** (`RenderPreview`, build/test) when Xcode is open, and **agent-device, AXe or MobileBuildMCP** for taps and gestures.
5. **Style Dictionary or Terrazzo** for DTCG tokens into `.xcassets`/Swift, plus auto-generated token stories.
6. **Distribution:** SPM, `.artifactbundle`, a signed Homebrew tap, and a Tuist Previews / Appetize recipe.

### Defer (post-MVP)
- The play-function DSL with dual execution (in-process plus XCUITest/AXe). Ship ViewInspector-backed play steps first if needed.
- Figma: `.figma.ts` Code Connect template generation, and a Figma screenshot panel via the Figma MCP.
- DocC integration (story snapshots embedded in articles, Markdown output for agents).
- Physical-device support (Bonjour, `devicectl` settings).
- Percy and Applitools adapters, and an Xcode 27 agent plug-in package.

### Skip
- **Building our own** diff engine, hosted visual-regression service, simulator tap driver or hot reload.
- Unmaintained or archived dependencies:
  - iOSSnapshotTestCase, GTXiLib, A11yUITests
  - playbook-ios (as a dependency)
  - SwiftGen, Sourcery, swift-doc, xcparse
  - Telegraph, Swifter
- **CocoaPods** distribution.
- The legacy Code Connect SwiftUI DSL.
- Xcode Source Editor Extensions.
- Dead or pivoted vendors: Lost Pixel, Specify, Cirrus CI.

## Open questions this research raises

- **Story source:** should `#Preview(arguments:)` be the primary story format? Xcode 27 makes it attractive, but it requires iOS 26+, and previews aren't addressable at runtime without SnapshotPreviews-style Mach-O scanning. Alternatively we could own a `Story` type and *generate* `#Preview`s from it.
- **Relationship to SnapshotPreviews and Prefire:** compete, build on, or contribute? SnapshotPreviews' discovery code is MIT and actively maintained under Sentry.
- **Headless rendering:** how stable will Xcode's headless `mcp-server` be for CI preview rendering, versus our own in-simulator renderer?
