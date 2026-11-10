# 03 · Discovery and the host app: how a dynamic storybook finds stories and runs them

Research thread 3 of 4. Questions: **how does a storybook app pick up a
user's components and stories, and how should the host app, the
simulator/device and the outside world (CLI, MCP, agents) fit together?**
Read [`../storybook-11-architecture-findings.md`](../storybook-11-architecture-findings.md)
first for project context. The story format itself is covered in
[`02-story-format.md`](02-story-format.md), and this document uses its
vocabulary (`Stories` protocol, `@Stories` macro, `StoryMeta`, `Story`,
`index.json` v5).

> Researched in October 2026 against Xcode 27.0 (27A266a, local `simctl` and
> `devicectl` help), Swift 6.3, and the source of the projects cited below,
> pinned to the commits that were read. Anything marked **[unverified]** rests
> on one informal source or on inference. Check it before relying on it.

## TL;DR

- **Discovery: use runtime records, with a static index alongside.** The
  `@Stories` macro emits a small `@used @section(...)` record per stories type,
  the same mechanism Swift Testing uses for `@Test` and `swift-play` uses for
  `#Playground` (SE-0492, Swift 6.3). The runtime enumerates the section in
  every loaded image. That gives zero-registration discovery with no private
  API and no hand-copied ABI structs.
  - **Fallback for toolchains older than 6.3, or code without the macro:** scan
    `__swift5_proto` for conformances to *our own* `Stories` protocol, as
    SnapshotPreviews does for `PreviewProvider`. This is stable in practice,
    but it reads ABI layouts by hand.
  - **Static index:** a **SwiftSyntax CLI** produces `index.json` without a
    build, for agents, CI and the host's story list.
- **`#Preview` is an importer, not the core.** Previews can be found at runtime
  through `PreviewRegistry` conformances, but rendering them needs `Mirror`
  over private `DeveloperToolsSupport` types (SnapshotPreviews ships a
  binary shim built against hand-patched SDK interfaces). Keep it behind a
  flag.
- **Integration: a Swift package plus a small host app target in the user's
  project (model a), which is the primary model.** The same runtime can also be
  embedded in the user's debug build (model d). A generic prebuilt host that
  `dlopen`s user code (model b) works only on the simulator. On devices running
  iOS 18 or later, dylibs outside the app bundle are refused even when signed
  by the same team. A Mac app (model c) is a later UI on top of the same
  CLI and daemon, not a prerequisite.
- **Hot reload is tiered:**
  - **Tier 0:** args, globals and story selection change instantly over the
    socket, with no code reload.
  - **Tier 1:** an incremental `xcodebuild` plus relaunch that restores the
    current story from launch arguments. Works everywhere, takes seconds.
  - **Tier 2, optional and simulator only:** InjectionNext-style function-body
    injection.
  - **Not available to third parties:** Xcode Previews' JIT. It relies on a
    private code-signature type and private agents.
- **Rendering happens in the app process.** A `StoryHostViewController` wraps
  each story in a fresh `UIHostingController` or UIKit container. It handles
  sizing modes, trait overrides and environment decorators, rebuilds the view
  tree on each render so state is isolated, and waits for a "settled" signal
  before taking a cropped `drawHierarchy` capture. For full-device frames it
  uses `simctl io screenshot` instead.
- **Communication: the app runs a WebSocket server, and a Swift CLI/daemon
  connects to it.** The server is a Network.framework `NWListener`. On the
  simulator the CLI connects over `localhost`. For devices it connects over
  USB (`iproxy`) or the LAN. Because the app listens rather than connecting
  out, devices need no local-network prompt. The daemon exposes the toolsets
  (`listStories`, `renderStory`, `setArgs`, `snapshot`, …) over MCP, the CLI and
  an SDK, following the Storybook 11 toolsets model. Launch arguments and
  `simctl openurl` are the zero-dependency fallback.

---

## 1. Compile-time discovery

Compile-time discovery means finding stories in source before or during the
build, and producing either generated Swift code (a registry) or data (a
manifest).

### 1.1 What Swift macros can and can't do

- **A macro only sees its own syntax.** In TSPL's words, "the AST passed to a
  macro implementation contains only the AST elements that represent the macro,
  not any of the code that comes before or after it." Macros run sandboxed,
  with no file system or network access, and they can't modify existing code
  ([TSPL Macros](https://github.com/swiftlang/swift-book/blob/main/TSPL.docc/LanguageGuide/Macros.md)).
  So **no macro can build a cross-file list of stories.**
- **No arbitrary global names.** Peer macros attached to top-level
  declarations can't introduce arbitrary names
  ([SE-0389](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0389-attached-macros.md)).
  Freestanding declaration macros follow the same naming rules
  ([SE-0397](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0397-freestanding-declaration-macros.md)).
- **The pattern that works:** the macro emits something per declaration (a
  conformance, a uniquely named type, or a static member) that a **runtime**
  mechanism can then find. Apple's `#Preview` does this. It expands to a
  compiler-named type that conforms to `DeveloperToolsSupport.PreviewRegistry`,
  which Apple describes as what "the system uses to locate previews at runtime"
  ([docs](https://developer.apple.com/documentation/developertoolssupport/previewregistry)).
  So macros are an *emitter* for runtime discovery (§2), not a discovery
  mechanism on their own.
- **Build cost.** Macros depend on swift-syntax:
  - Built from source, Point-Free measured about +20 s on a clean debug build
    and 4+ min on a release WMO build
    ([Point-Free](https://www.pointfree.co/blog/posts/171-mitigating-swiftsyntax-build-times)).
  - Prebuilt swift-syntax arrived as opt-in in Xcode 16.4 / SwiftPM 6.1, and is
    reported on by default for macros in 6.2
    ([forums](https://forums.swift.org/t/preview-swift-syntax-prebuilts-for-macros/80202)).
    Results are reported as mixed.
  - Xcode also asks the user to trust each macro package, and CI needs
    `-skipMacroValidation`.
- **Takeaway:** the macro must stay **optional** sugar, as thread 02 already
  concluded.

### 1.2 SwiftPM build-tool plugins (SE-0303)

Source: [SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md)
and [WritingBuildToolPlugin.md](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/Plugins/WritingBuildToolPlugin.md).

- **A plugin returns commands; the build runs them later.** There are two kinds:
  - `.buildCommand` has declared inputs and outputs and is incremental. It
    suits a single aggregated `StoryRegistry.swift` whose inputs are the
    target's sources.
  - `.prebuildCommand` runs on every build, and everything in its output
    directory is compiled into the target. SwiftPM's own API docs warn of "a
    significant performance impact".
- **Prebuild commands must use binary tools.** SwiftPM rejects
  executables built from source ("a prebuild command cannot use executables
  built from source"), so the scanner ships as an `.artifactbundle`. This is
  exactly what Prefire does
  ([Package.swift](https://github.com/BarredEwe/Prefire/blob/main/Package.swift)).
- **Sandbox:** the package directory is read-only, there is no network, and
  the plugin can write only to `pluginWorkDirectory`.
- **Reading other targets' sources:**
  - **SwiftPM packages: yes.** `PluginContext.package` exposes the package
    graph, and each `Target` exposes its `dependencies` and `sourceFiles`.
    Prefire's test plugin walks `target.dependencies` to find the target under
    test
    ([TestedTargetFinder.swift](https://github.com/BarredEwe/Prefire/blob/main/Plugins/PrefireTestsPlugin/TestedTargetFinder.swift)).
  - **Xcode projects: limited.** `XcodeBuildToolPlugin` works from
    `XcodeTarget.inputFiles` and `context.xcodeProject.targets`. Prefire
    matches targets by name heuristics, which suggests that dependency edges
    aren't exposed **[unverified; XcodeProjectPlugin is closed source]**.
- **Friction:**
  - Xcode asks the user to trust each plugin.
  - CI needs `-skipPackagePluginValidation`.
  - In Xcode projects, the user must add the plugin to each target under
    *Build Phases ▸ Run Build Tool Plug-ins*.
- **Fundamental limit:** a plugin sees syntax, not types. It can't tell whether
  `Foo` is a `View` or a `UIView` without heuristics.

### 1.3 SwiftPM command plugins (SE-0332)

- **How they run:** `swift package storybook-generate`, or from the Xcode
  project context menu
  ([SE-0332](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0332-swiftpm-command-plugins.md)).
- **Writing to the package:** `writeToPackageDirectory(reason:)` asks the user,
  or the CLI grants it with `--allow-writing-to-package-directory`.
- **Extra powers:** a command plugin can ask SwiftPM to build products, run
  tests and fetch symbol graphs.
- **Good for one-off scaffolding:** `storybook init` (create the host target
  and config) or `storybook index` (write `index.json`). Sourcery ships this
  way ([Sourcery](https://github.com/krzysztofzablocki/Sourcery)).
- **Bad for anything that has to stay in sync on every build**, since it only
  runs when invoked.

### 1.4 Standalone SwiftSyntax scanner (CLI)

A plain executable that parses sources with `SwiftParser` and visits the
declarations it cares about.

- **Prior art: Prefire.** It visits `MacroExpansionDeclSyntax` and
  `MacroExpansionExprSyntax` named `Preview` and extracts the display name,
  traits, layout and body text
  ([PreviewLoader.swift](https://github.com/BarredEwe/Prefire/blob/df2ea9cfd4d80419ab03c492f9e3a9f5aabd174b/PrefireExecutable/Sources/PrefireCore/Previews/PreviewLoader.swift#L56-L86),
  [PreviewParser.swift](https://github.com/BarredEwe/Prefire/blob/df2ea9cfd4d80419ab03c492f9e3a9f5aabd174b/PrefireExecutable/Sources/PrefireCore/Previews/PreviewParser.swift#L30-L43)).
- **Prefire's weakness: it copies source text.** A `#Preview` can't be
  referenced by name, so it pastes each preview body verbatim into generated
  code
  ([template](https://github.com/BarredEwe/Prefire/blob/df2ea9cfd4d80419ab03c492f9e3a9f5aabd174b/Templates/PreviewModelsTemplates.swift#L55-L100)).
  That breaks on `fileprivate` helpers and needs `@testable import`.
- **Our scanner doesn't have that problem.** A `Stories` type has a name, so
  generated code can just reference `PayButtonStories.self`.
- **The scanner's two jobs:**
  1. **Produce `index.json`** without compiling. This is the Storybook
     indexer contract: titles, names, ids and tags must be literals, which the
     `@Stories` macro enforces (see thread 02, §5.4).
  2. **Optionally write `StoryRegistry.swift`**
     (`[PayButtonStories.self, …]`) for toolchains or modes where runtime
     discovery isn't available.
- **Packaging:** one binary, used three ways:
  - by the CLI (`storybook index`);
  - by a command plugin;
  - by a build-tool plugin, as an artifactbundle.
- **Sourcery** ([repo](https://github.com/krzysztofzablocki/Sourcery)) can do
  the same through annotations and Stencil templates, with a `--watch` mode.
  But it is a large general-purpose dependency for a narrow job, and Prefire
  appears to have moved off it to its own SwiftSyntax and Stencil engine
  **[when, unverified]**.

### 1.5 Generated host targets (Tuist / XcodeGen)

For teams that already use [Tuist](https://docs.tuist.dev) or
[XcodeGen](https://github.com/yonaskolb/XcodeGen), the storybook host target
can be declared there: a `.storybook()` helper in Tuist, or a YAML snippet in
XcodeGen. This is nice to have, not a requirement. For everyone else,
`storybook init` should edit or create the project, or the host can be a
standalone SwiftPM-only app (§3a).

### 1.6 Compile-time discovery trade-offs

| Mechanism | Sees | Cost | Friction | Good for |
|---|---|---|---|---|
| Macro alone | One declaration | swift-syntax build, trust prompt | Users adopt macro | Emitting records, validating literals |
| Build-tool plugin (`.buildCommand`) | Target sources (+ deps in SPM) | Incremental | Trust prompt, per-target setup in Xcode | Generated registry kept in sync |
| Build-tool plugin (`.prebuildCommand`) | Same | Every build | Same + binary-only tool | Same, simpler to write |
| Command plugin | Whole package | On demand | Write-permission prompt | `init`, `index`, scaffolding |
| Standalone SwiftSyntax CLI | Any files | On demand / watch | None | `index.json`, CI, agents |
| Sourcery | Any files | On demand / watch | Big dependency, templates | Teams already using it |

---

## 2. Runtime discovery

Runtime discovery means the running app finds stories in its own loaded
images, so nothing has to be generated or kept in sync.

### 2.1 Scanning protocol-conformance records (`__swift5_proto`)

This is how EmergeTools'
[SnapshotPreviews](https://github.com/EmergeTools/SnapshotPreviews) finds every
`PreviewProvider` and `#Preview`. The code is in
[`ConformanceLookup.swift#L83-L120`](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/SnapshotPreviewsCore/ConformanceLookup.swift#L83-L120).

1. **Pick the images.** Loop over `_dyld_image_count()`. Skip images in the
   shared cache (`MH_DYLIB_IN_CACHE`) and system paths (`.simruntime`,
   `/usr/lib/`, `/System/Library/`).
2. **Read the section.** `getsectiondata(header, "__TEXT", "__swift5_proto", &size)`
   returns an array of `Int32` relative offsets to
   `ProtocolConformanceDescriptor`s.
3. **Filter by protocol.** Resolve each record's protocol descriptor (through
   an indirect pointer when the low bit is set) and keep it if the name is
   `PreviewProvider` or `PreviewRegistry` (L39-75).
4. **Get the type.** Read the conforming type's context descriptor and call its
   metadata access function, then cast:
   `unsafeBitCast(accessor(), to: Any.Type.self) as! any PreviewRegistry.Type`
   ([SnapshotPreviewsCore.swift#L237-L262](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/SnapshotPreviewsCore/SnapshotPreviewsCore.swift#L237-L262)).

**Caveat: the ABI structs are copied by hand.** `ProtocolConformanceDescriptor`
and related structs are hand-copied from Swift's `include/swift/ABI/Metadata.h`
([MetadataTypes.swift](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/SnapshotPreviewsCore/MetadataTypes.swift#L10-L40)).
Swift's ABI has been stable on Apple platforms since Swift 5, so these
layouts don't change in practice. Still, it's unsafe pointer code that we
would have to own.

**A variant: scanning `__swift5_types`.** eure's
[swift-storybook](https://github.com/eure/swift-storybook) scans
`__TEXT,__swift5_types` instead. It keeps types whose names contain
`PreviewRegistry` and matches its own macro types by a magic substring in the
name
([machOLoader.swift](https://github.com/eure/swift-storybook/blob/edf96f09/Sources/StorybookKit/Internals/machOLoader.swift#L98-L255)).
Matching on names is cruder than matching on protocol conformances.

**Scanning for our own protocol avoids the private-API problem.** The scan
itself uses only ABI structures. The *private* part of SnapshotPreviews comes
afterwards, when it pulls a view out of the `DeveloperToolsSupport.Preview`
struct (§2.5). If the scan looks for conformances to **our** `Stories`
protocol, the cast gives a `Stories.Type` whose `meta` and `all` we control,
so no private API is involved. This is the fallback discovery path
recommended below.

### 2.2 Linker-section records (`@section` / `@used`)

This is Swift Testing's mechanism, and since Swift 6.3 it uses official
language features.

**What the macro emits.** `@Test` expands to a peer declaration
([TestContentGeneration.swift#L50-L110](https://github.com/swiftlang/swift-testing/blob/648c87a3170d064deb18c61d7eb5f11cd87915c9/Sources/TestingMacros/Support/TestContentGeneration.swift#L50-L110)):

```swift
@section("__DATA_CONST,__swift5_tests")   // ELF: "swift5_tests", COFF: ".sw5test$B"
@used
private nonisolated static let __testContentRecord…: Testing.__TestContentRecord = (
  0x74657374 /* 'test' */, 0,
  { outValue, type, hint, _ in Testing.Test.__store(generator, into: outValue, asTypeAt: type) },
  0, 0)
```

- **Record layout:**
  `(kind: UInt32, reserved1: UInt32, accessor: @convention(c) (...) -> Bool, context: UInt, reserved2: UInt)`
  ([TestContentRecord.swift#L23-L44](https://github.com/swiftlang/swift-testing/blob/648c87a3170d064deb18c61d7eb5f11cd87915c9/Sources/_TestDiscovery/TestContentRecord.swift#L23-L44),
  spec in `Documentation/ABI/TestContent.md`).
- **Kinds are 4-character codes:** `'test'`, `'exit'`, and `'play'` (used by
  `#Playground`). **The spec explicitly invites third-party kinds**: you
  request one through a GitHub issue, and Swift Testing ignores kinds it
  doesn't know.

**How records are enumerated.**
[`SectionBounds.swift`](https://github.com/swiftlang/swift-testing/blob/648c87a3170d064deb18c61d7eb5f11cd87915c9/Sources/_TestDiscovery/SectionBounds.swift#L43-L152)
does the work:

- **Darwin:** list image headers with `objc_copyImageHeaders` (with fallbacks),
  skip the shared cache, then call
  `getsectiondata(mh, "__DATA_CONST", "__swift5_tests")`.
- **ELF:** `swift_enumerateAllMetadataSections`.
- **Static linking:** `section$start$…` symbols.

**Language support** ([SE-0492](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md)):

- **Status:** "Implemented (Swift 6.3)", accepted with modifications on
  2025-10-16
  ([announcement](https://forums.swift.org/t/accepted-with-modifications-se-0492-section-placement-control/82701)).
  Earlier toolchains have `@_section`/`@_used` behind the experimental feature
  `SymbolLinkageMarkers`.
- **Constraints:**
  - Only global or static non-generic stored properties can be placed in a
    section.
  - Their initializer must be a **constant expression**: literals,
    capture-free closures, tuples, `InlineArray`. Strings are not allowed.
- **Consequence:** a record can't hold a story title. It holds an *accessor
  function*, and the accessor returns the metadata.

**Prior art outside testing.** Apple's
[swift-play-experimental](https://github.com/apple/swift-play-experimental)
reuses this mechanism for `#Playground`:

- the macro emits a `'play'` record
  ([PlaygroundMacro.swift#L84-L110](https://github.com/apple/swift-play-experimental/blob/187e8ed7/Sources/PlaygroundMacros/PlaygroundMacro.swift#L84-L110));
- it enumerates the records through `_TestDiscovery`'s
  `DiscoverableAsTestContent`, using a hint so it doesn't call every accessor.

**This is the closest existing blueprint for `@Stories`.**

**How we'd use it.** `@Stories` adds a peer record whose accessor writes
`PayButtonStories.self` as `any Stories.Type`. Two ways to enumerate:

- Depend on `_TestDiscovery`
  (`@_spi(Experimental) @_spi(ForToolsIntegrationOnly) import _TestDiscovery`).
  This is underscored SPI, so expect churn.
- Use our own section, e.g. `__DATA_CONST,__swift5_story`, plus about 60 lines
  of `getsectiondata` code. This is preferable, because it avoids a dependency
  on SPI.

**Open item: dead stripping.** `@used` exists to stop the linker from
dead-stripping a symbol, but we haven't verified that records survive
`-dead_strip` plus LTO in a Release-like configuration **[unverified]**.
Storybook builds are normally Debug, so this matters less.

### 2.3 The Objective-C runtime

- **Examples:**
  - MDC's
    [catalog-by-convention](https://github.com/material-foundation/cocoapods-catalog-by-convention)
    walks `objc_getClassList` and keeps `UIViewController` subclasses that
    implement `+catalogMetadata`
    ([CBCRuntime.m](https://github.com/material-foundation/cocoapods-catalog-by-convention/blob/develop/src/private/CBCRuntime.m#L158-L185)).
  - [NativeBook](https://github.com/psharanda/NativeBook) finds `story_*`
    methods with `class_copyMethodList`.
- **Drawbacks:**
  - Only works for `NSObject` subclasses, so it excludes SwiftUI `struct`s and
    our `enum` stories types.
  - Touches every class in the process, which is slow and can trigger
    `+initialize`.
- **Verdict:** not worth it now that §2.1 and §2.2 exist. Its only use is
  `+load` or `__attribute__((constructor))` hooks that start the runtime
  automatically (SnapshotPreviews does this in
  [Initializer.m](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/Snapshotting/Initializer.m#L11-L17)).

### 2.4 Manual registration

[Playbook](https://github.com/playbook-ui/playbook-ios) has no scanning at all:

- `Playbook.default.add(MyScenarios.self)`, where `ScenarioProvider` is
  `static func addScenarios(into:)`
  ([Playbook.swift#L52-L73](https://github.com/playbook-ui/playbook-ios/blob/ef0398b4dd394f0b6f23c6a6d96b1f7c00632aa0/Sources/Playbook/Playbook.swift#L52-L73)).

**Trade-off:** it is simple and fully App Store safe, but the registration
list drifts from the stories that exist. We should still support it as an
escape hatch:

```swift
Storybook.register(PayButtonStories.self)
```

The generated `StoryRegistry.swift` from §1.4 is just this call written by a
tool.

### 2.5 `#Preview` at runtime: possible, but fragile

1. **Finding previews is the easy part.** Call `makePreview()` on each
   `PreviewRegistry` type found by §2.1. That method is in the public
   `.swiftinterface`.
2. **Rendering is where it gets fragile.** The returned `Preview` is opaque.
   SnapshotPreviews walks it with `Mirror`:
   - `traits` gives `PreviewLayout` and orientation;
   - `source` or `dataSource.preview` gives the view factory
     ([SnapshotPreviewsCore.swift#L21-L114](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/SnapshotPreviewsCore/SnapshotPreviewsCore.swift#L21-L114)).
3. **Those source types are private SDK types:** `ViewPreviewSource`,
   `UIViewControllerPreviewSource`, and, on iOS 18, `DefaultPreviewSource`.
   - SnapshotPreviews ships a prebuilt `PreviewsSupport.xcframework` compiled
     against **hand-patched SDK `.swiftinterface`s** that expose them through
     `@_spi(Private)`.
   - It also uses `_VariadicView` to split multi-view previews
     ([PreviewsSupport/README.md](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/PreviewsSupport/README.md),
     [ViewSelector.swift](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/SnapshotPreviewsCore/ViewSelector.swift#L11-L41)).
   - These types changed between iOS 17 and 18.
4. **Apple warns against defining a registry yourself:** "If you define a
   preview registry directly, the behavior is undefined"
   ([docs](https://developer.apple.com/documentation/developertoolssupport/previewregistry)).
5. **Optimized builds can strip previews.** Whole-module-optimized builds "can
   remove unreferenced preview declarations"
   ([SnapshotPreviews README](https://github.com/EmergeTools/SnapshotPreviews#preview-gallery)).

**Conclusion:** keep a `#Preview` importer as an **optional module**
(`StorybookPreviewImport`). It could vendor or depend on SnapshotPreviews'
`PreviewsSupport`, it should be tagged `preview`, and it should be read-only
(no args). Matching thread 02's recommendation, it should not be the core.

### 2.6 App Store safety

This doesn't matter for a dev tool, but here is the record:

- **Safe:** section scanning (§2.2), conformance scanning (§2.1, public dyld
  APIs plus pointer arithmetic), and manual registration.
- **Not safe:** the `#Preview` importer (private SDK symbols, `_VariadicView`)
  and `DYLD_INSERT_LIBRARIES`.
- **Recommendation:** gate everything behind a `STORYBOOK` compilation
  condition or a separate configuration, so Release builds contain none of it.

### 2.7 Runtime discovery trade-offs

| Mechanism | Private API? | Hand-written ABI? | Needs macro? | Min toolchain | Finds `#Preview`? |
|---|---|---|---|---|---|
| `@section` records (own section) | No | No (our own record layout) | Yes (`@Stories`) | Swift 6.3 | No |
| `__swift5_proto` scan for `Stories` | No | Yes (conformance descriptors) | No | Any Swift 5+ | No |
| `__swift5_proto` scan for `PreviewRegistry` + Mirror | **Yes** | Yes | No | iOS 17+ | Yes |
| ObjC runtime | No | No | No | Any | No (NSObject only) |
| Manual / generated registry | No | No | No | Any | Via codegen only |

---

## 3. Integration models

### (a) A Swift package plus a small host target in the user's project (recommended)

**What the user does:**

1. Add the `Storybook` package.
2. Run `storybook init` (CLI or command plugin). It creates a
   `<App>Storybook` iOS app target that:
   - links the modules containing stories;
   - links `StorybookUI` (browser), `StorybookRuntime` (registry, renderer,
     agent server) and, optionally, `StorybookPreviewImport`;
   - contains a two-line `@main`.

```swift
import StorybookUI
import DesignSystem      // modules with stories
import PaymentsUI

@main struct AppStorybook: App {
    var body: some Scene { StorybookScene(configuration: AppStorybookConfig.self) }
}
```

**Pros:**

- Everything is compiled by the user's own toolchain, with the user's flags,
  signing, resources and dependencies.
- It runs on both simulator and device.
- Debugging, breakpoints and Instruments work as usual.
- Only modules linked into the host contribute stories, so the scope is
  explicit.
- Discovery works out of the box, because the story modules are statically or
  dynamically linked into the host and their sections are loaded.

**Cons:**

- Stories have to live in a module the host can import. They can't live inside
  an app target, because you can't import an app target. Thread 02's §5.5
  already points this way: stories go in the component's module, or in a
  `FooStories` module that uses `@testable import`.
- Teams with "everything in the app target" projects need model (d) instead.
- We have to edit `.pbxproj`. Possible approaches: the `XcodeProj` library,
  generating a tiny separate `Storybook.xcodeproj` that references the user's
  packages, or Tuist/XcodeGen.

**Prior art:** this is the model of PreviewGallery
([README](https://github.com/EmergeTools/SnapshotPreviews#preview-gallery)),
Playbook and swift-storybook.

### (b) A generic prebuilt host app that loads user code with `dlopen`

**Idea:** we ship `Storybook.app` once. The user's components are built as a
dynamic framework (or bundle), and the host loads it at runtime and discovers
stories in the newly loaded image. The §2.1 and §2.2 scanners already work on
any image, and `_dyld_register_func_for_add_image` gives a callback when one is
added.

**Simulator: works.**

- Simulator apps can `dlopen` arbitrary paths on the Mac's file system.
  InjectionIII and InjectionNext rely on this: in simulator mode the Mac just
  sends a file path to load
  ([InjectionNext](https://github.com/johnno1962/InjectionNext)).

**Device: effectively impossible.**

- Apple DTS: "you can only open a library that's either built in to the OS or
  embedded within your app… Developer Mode punches holes… tightly constrained
  to the requirements of Xcode"
  ([forums 773210](https://developer.apple.com/forums/thread/773210)).
- On iOS 18 and later (reproduced on iOS 26.4.2 with Xcode 26.3), a dylib
  copied into the data container fails with `code signature invalid` even when
  it's signed by the same team
  ([InjectionNext #81](https://github.com/johnno1962/InjectionNext/issues/81)).
- Loading a framework **embedded in the bundle** works, but that requires
  re-signing and reinstalling the app, which brings us back to model (a).

**ABI and dependency coupling.** The prebuilt host and the user framework must
agree on:

- the Swift runtime and SDK version;
- the `Storybook` runtime module itself (it must be a dynamic framework shared
  by both, or its types will be duplicated);
- every transitive dependency the user's code links.

Resources, asset catalogs, fonts registered in `Info.plist`, entitlements and
app-group containers all belong to the host, not the user's app, so many real
components will render wrongly.

**Verdict:** this is the model that sounds most like "Storybook" (one
generic viewer for everyone), but it fights the platform. Keep it as a
possible **simulator-only quick-look mode** for pure-SwiftUI design-system
packages that have no app-level dependencies. Don't build the architecture
around it.

### (c) A Mac app that drives the simulator

**What it would be:** a native macOS UI with the story tree, Controls, Actions
and a11y panels, while the stories render in a simulator or device running
the model (a) host. It's essentially Storybook's manager, with the iOS app as
the preview.

**Showing the simulator inside the Mac app:**

- There is **no public API** for embedding the simulator's display.
- **Private route:** idb/FBSimulatorControl read the simulator's IOSurface
  framebuffer and inject input through private HID services, and they say they
  "leverage many of Private Frameworks that are used by Xcode"
  ([idb](https://github.com/facebook/idb),
  [FBSimulatorControl docs](https://fbidb.io/docs/fbsimulatorcontrol)). This
  breaks with Xcode releases.
- **Public route:** poll `simctl io screenshot -` at a few fps, or stream
  through a helper like [serve-sim](https://github.com/EvanBacon/serve-sim)
  (MJPEG plus a WebSocket control channel). serve-sim's exact capture
  mechanism is **[unverified]**.
- **Alternative:** don't embed it. Put the Mac panels next to Simulator.app or
  Xcode 27's Device Hub
  ([WWDC26 session 258](https://developer.apple.com/videos/play/wwdc2026/258/)).
  Or have the app on the device or simulator stream its own story view (an
  in-process capture of just the story, which also works on devices).

**Verdict:** valuable later as a polished UI, but every capability it needs
(list, render, set args, snapshot, events) should first exist as the
**CLI/daemon toolset**. The Mac app is then just one more client, like MCP.
Start with the in-app browser (`StorybookUI` on the device itself), the CLI
and MCP.

### (d) Embedding the catalog inside the user's debug build

**What the user does:** link `StorybookRuntime` and `StorybookUI` into their
real app's Debug or internal configuration. They present it from a debug
menu, a shake gesture, a launch argument (`-StorybookEnabled YES`) or a deep
link.

**Pros:**

- Zero new targets.
- Works for stories in the app target itself.
- Stories render with the real app's fonts, assets, DI container and feature
  flags.
- Testers get it in internal builds, which is how PreviewGallery is usually
  shipped
  ([README](https://github.com/EmergeTools/SnapshotPreviews#preview-gallery)).

**Cons:**

- Launching goes through the real app's startup (analytics, auth, migrations),
  which is slower and noisier.
- Global singletons leak into stories.
- Story code ends up in a build that's closer to shipping, so it must be
  gated by `#if STORYBOOK`.

**Implementation:** this is the same runtime as (a). Only the entry point
differs (`StorybookScene` versus `Storybook.present(from:)` or
`StorybookRootView`). The agent server and CLI work the same way. The CLI only
needs to know the bundle id and the launch argument that opens the catalog.

### Integration trade-offs

| | (a) Host target | (b) Prebuilt host + dlopen | (c) Mac app | (d) Embedded in debug app |
|---|---|---|---|---|
| Device support | ✅ | ❌ (iOS 18+) | ✅ (as client of a/d) | ✅ |
| Setup cost | Medium (new target) | Low (in theory) | Adds an app | Low |
| Real resources/deps | ✅ | ❌ often broken | n/a | ✅✅ |
| Story isolation from app globals | ✅ | ✅ | n/a | ⚠️ |
| Stories in app target | ❌ | ❌ | n/a | ✅ |
| Fragility | Low | High (ABI/dep coupling) | Medium–high if embedding sim | Low |

**Recommendation:** support (a) and (d) from day one with one runtime. Build
(c) later as a toolset client. Skip (b), except perhaps as a simulator-only
experiment.

---

## 4. Hot reload and fast iteration

### 4.1 How Xcode Previews works

**Xcode 11–15: "dynamic replacement".**

- **Build:** Previews built a *separate* copy of the project with
  `-enable-implicit-dynamic -enable-private-imports -enable-dynamic-replacement-chaining`.
  This is visible in open-source swift-build (`SwiftCompiler.swift`,
  `Settings.swift`, `SWBPreviewStyle.dynamicReplacement`;
  [swift-build](https://github.com/swiftlang/swift-build)).
- **Thunk files:** for each previewed file, Xcode generated a
  `*.preview-thunk.swift` file containing:
  - `@_dynamicReplacement(for: body)` implementations;
  - `@_private(sourceFile:)` imports;
  - every literal wrapped as `__designTimeString("#7464.[1].[0]…", fallback: "Hello")`
    (and `__designTimeInteger` and so on), keyed into a table of design-time
    values.
- **Three tiers of edit:**
  - Editing a literal updated the preview without recompiling.
  - Editing a function body recompiled only the thunk dylib.
  - Structural edits needed a full rebuild.
- **Host:** the thunk was loaded into `XCPreviewAgent` (private
  `_XCPreviewKit`), which talked to Xcode over XPC.
- **Sources:** [WWDC19 233](https://developer.apple.com/videos/play/wwdc2019/233),
  [Guardsquare](https://www.guardsquare.com/blog/behind-swiftui-previews),
  [fatbobman](https://fatbobman.com/en/posts/how-swiftui-preview-works).

**Xcode 16 and later: the JIT ("XOJIT").**

- **Apple's public description:** previews "uses the same build products for
  your project and reassembles your program on the fly"
  ([WWDC24 10135](https://developer.apple.com/videos/play/wwdc2024/10135/)).
- **Build layout** (with `ENABLE_DEBUG_DYLIB`, the default for Debug):
  - `MyApp`: a stub executable.
  - `MyApp.debug.dylib`: all of the app's code.
  - `__preview.dylib`: an empty dylib for early interposition.
  - Source: [Apple: build product layout changes](https://developer.apple.com/documentation/xcode/understanding-build-product-layout-changes).
- **What swift-build source adds:**
  - The stub links `libPreviewsJITStubExecutor.a`.
  - Previews asks the build system for the *frontend* command line of a single
    file (`SWBPreviewInfo`), with no thunk dylib.
- **The JIT itself** (Lang Hames,
  [LLVM Dev Meeting 2025](https://llvm.org/devmtg/2025-10/slides/technical_talks/hames.pdf)):
  - It is LLVM ORC/JITLink. A controller process links object files into the
    running app (the executor).
  - On first definition, `foo` gets a stub that jumps through a pointer. Each
    edit links `foo$body_N` and repoints the pointer.
  - dyld supports *pseudo-dylibs* for JIT'd code.
  - JIT'd code is signed with **"a custom *Preview* signature type, only usable
    for apps in development mode"**. That is why Previews can run on a device
    and third parties can't.
- **`#Preview`** expands to a `PreviewRegistry` conformer (§2.5).

**What third parties can reuse:**

- **Public:** `#Preview`, `PreviewModifier` and traits, the `PreviewRegistry`
  protocol, the debug-dylib layout, and swift-build's open-source preview
  plumbing, which shows how to get per-file frontend commands.
- **Private:** the JIT controller, the Preview signature type, and the agents.
- **Xcode 26.3+ also exposes an MCP server.** In 26.6, its "Preview Snapshot"
  tool can render variants (light/dark, orientation, type size)
  ([26.6 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_6-release-notes)).
  An agent could use it for `#Preview`s, but only with Xcode running. It is
  not something we can build on.

### 4.2 InjectionIII, InjectionNext, Inject

**Pipeline** ([InjectionIII](https://github.com/johnno1962/InjectionIII),
[InjectionNext](https://github.com/johnno1962/InjectionNext),
[Inject](https://github.com/krzysztofzablocki/Inject)):

1. **Watch.** A Mac file watcher sees a changed file.
2. **Recover the compile command.** InjectionIII greps the latest
   `.xcactivitylog`. InjectionNext launches Xcode with `SOURCEKIT_LOGGING=1`
   and parses its output.
3. **Build a dylib.** Recompile that one file and link it into
   `eval_injection_N.dylib` with `-undefined dynamic_lookup`.
4. **Load it** in the app with `dlopen`.
5. **Rebind.** Use fishhook to rebind the dylib's Swift symbols. This works
   because the app is linked with `-Xlinker -interposable`. Patch vtables for
   non-final classes and swizzle ObjC methods.
6. **Notify.** Call `@objc func injected()` on live instances.
7. **SwiftUI:** `@ObserveInjection` plus `.enableInjection()` forces a redraw,
   and erases `body` to `AnyView`, because changing a concrete `some View` type
   is a layout change.

**Transport:**

- The app connects out to the Mac on `127.0.0.1:8887`.
- Devices find the Mac with multicast.
- Simulator apps receive a file path to load. Devices receive the dylib bytes,
  signed with the developer identity
  ([InjectionClient.h, NextCompiler.swift](https://github.com/johnno1962/InjectionNext)).

**Fragility:**

- Xcode 16.3 stopped logging frontend commands. The workaround is
  `EMIT_FRONTEND_COMMAND_LINES=YES`.
- It is incompatible with `COMPILATION_CACHE_ENABLE_CACHING`.
- fishhook needed a `vm_protect` fix in 2026.
- Device injection is blocked on iOS 18+ by the dlopen policy above
  ([#81](https://github.com/johnno1962/InjectionNext/issues/81)).
- Only function bodies can change, not stored properties or type layouts.

### 4.3 What a third-party storybook can realistically offer

| Tier | Mechanism | Sim | Device | Latency | Notes |
|---|---|---|---|---|---|
| **0 — data** | Args, globals, story selection, viewport sent over the socket; story re-renders | ✅ | ✅ | instant | Covers the bulk of Storybook-style iteration. No code loading. |
| **1 — rebuild & restore** | CLI watches files → incremental `xcodebuild` → `simctl install`+`launch` (or `devicectl`) with `-StorybookStory <id> -StorybookArgs <json>` → app reconnects | ✅ | ✅ | seconds | Always correct. Debug-dylib layout keeps relinks small. Restore state via launch args so the user lands where they were. |
| **2 — injection** | Integrate with InjectionNext/InjectionLite if present (or reimplement with swift-build-derived commands); runtime re-renders current story on `injected` notification | ✅ | ❌ | sub-second | Opt-in. Fragile across Xcode releases. Our runtime can render stories through `AnyView` and re-render on a notification, so no `@ObserveInjection` is needed in story code. |
| — | Xcode Previews JIT | — | — | — | Private; not available. |

**Recommendation:** ship tiers 0 and 1 first. Design the runtime so a
"code changed, re-render" notification is a first-class event, so tier 2 can
be added later.

---

## 5. Rendering pipeline

All rendering happens **in the app process**, in a `StoryRenderer` that the
in-app browser, the agent server and snapshot runs all use.

### 5.1 Hosting

- **SwiftUI stories.** Each render gets a **new** `UIHostingController`, with
  the root view wrapped in decorators. For intrinsic sizing, set
  `sizingOptions = .intrinsicContentSize` (iOS 16+). SnapshotPreviews'
  `ExpandingViewController` does the same
  ([ExpandingViewController.swift](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/SnapshotPreviewsCore/ExpandingViewController.swift#L17-L75)).
- **UIKit stories.** `UIView` and `UIViewController` factories are put in a
  container controller. Decorators apply as SwiftUI modifiers when the UIKit
  view is wrapped with `UIViewRepresentable`, or as trait overrides on the
  container.
- **One `Story` type covers both** (thread 02's `render`), returning
  `some View` or using `StoryView(uiView:)` / `StoryView(viewController:)`
  wrappers.

### 5.2 Sizing modes

Storybook calls these "layout": `centered`, `fullscreen`, `padded`.
Apple's equivalents are `PreviewLayout` and the `.sizeThatFitsLayout` and
`.fixed` traits.

| Mode | Implementation |
|---|---|
| `fullscreen` / device | Story fills the window/safe area; snapshot = window bounds |
| `sizeThatFits` | `sizeThatFits(in:)` against the viewport width, `safeAreaRegions = []` (iOS 16.4+) so safe area doesn't pad the result |
| `fixed(w,h)` | Width/height constraints |
| `padded`/`centered` | `sizeThatFits` + decorator padding, centered in canvas |

- **swift-snapshot-testing** implements the same three cases
  (`.device(config:)`, `.fixed`, `.sizeThatFits`) and removes safe areas for
  `sizeThatFits`
  ([SwiftUIView.swift](https://github.com/pointfreeco/swift-snapshot-testing/blob/28e5de025e3fd98991791bfbf83023ab3708da03/Sources/SnapshotTesting/Snapshotting/SwiftUIView.swift#L39-L80)).
- **Scroll views:** SnapshotPreviews also expands them to their full content
  height for "full page" captures.

### 5.3 Device and trait overrides (globals and decorators)

- **SwiftUI environment:** `colorScheme`, `dynamicTypeSize`, `locale`,
  `layoutDirection`, `legibilityWeight`, plus app-specific keys. These are cheap
  and apply to SwiftUI only.
- **UIKit traits.** These reach both UIKit and SwiftUI content.
  - **iOS 17 and later:** `traitOverrides` on the hosting window scene or
    container controller (`UITraitOverrides`).
  - **Older:** `setOverrideTraitCollection(_:forChild:)`, which
    swift-snapshot-testing uses
    ([View.swift#L1025-L1052](https://github.com/pointfreeco/swift-snapshot-testing/blob/28e5de025e3fd98991791bfbf83023ab3708da03/Sources/SnapshotTesting/Common/View.swift#L1025-L1052)).
  - **Faked traits and safe area:** Playbook subclasses `UIWindow` to override
    `traitCollection` and `safeAreaInsets`
    ([SnapshotWindow.swift](https://github.com/playbook-ui/playbook-ios/blob/ef0398b4dd394f0b6f23c6a6d96b1f7c00632aa0/Sources/PlaybookSnapshot/SnapshotSupport/Internal/SnapshotWindow.swift#L3-L17)).
- **Device "viewports":** render into a canvas of a given device size with
  fake safe-area insets, like `ViewImageConfig.iPhone13`. This is not a real
  device: it gets size, safe area and traits right, but not
  `UIScreen.main.scale` or idiom-specific behaviour. For true fidelity,
  run on the matching simulator. The CLI can boot one and use
  `simctl ui <dev> appearance dark` and `simctl ui <dev> content_size …` to
  set system-wide settings from outside.
- **Deterministic captures:**
  - `simctl status_bar override --time 9:41 …`;
  - optionally freeze time. SnapshotPreviews hooks `gettimeofday`; injecting a
    clock dependency is cleaner.

### 5.4 Isolating per-story state

- **Fresh view tree per render.** A new hosting controller, plus
  `.id(renderToken)`, guarantees that `@State` and `@StateObject` don't survive
  a story switch or an args reset. When only args change, keep the tree and
  push new args through an `@Observable` args box, so
  interactive state survives (this matches Storybook, where changing args
  doesn't remount).
- **Per-story dependencies.** Loaders and decorators produce an environment
  (DI container, mock services) per render. Singletons are the user's problem,
  but model (a) keeps them away from the real app's startup.
- **Actions.** `StoryAction` closures publish events to the runtime's event
  bus, which the Actions panel and the agent toolset can see.
- **Crash isolation.** A crashing story kills the app. The CLI should detect
  the dropped connection and relaunch with `-StorybookSkip <id>`. It should
  also record the crash against the story, the way Storybook's test runner
  reports a failed render.

### 5.5 Settling, capture, and rendering many stories

- **Settle.** "Rendered" must mean the layout has settled, not just that the
  view was mounted. The steps are:
  1. `layoutIfNeeded`;
  2. wait two `CADisplayLink` frames, or a `CATransaction` completion;
  3. let the run loop go idle;
  4. optionally wait for an `await`ed "story ready" signal from loaders or
     images.

  Only then reply `storyRendered` (Storybook's own event name).
- **Capture in-app:** `drawHierarchy(in:afterScreenUpdates:)` via
  `UIGraphicsImageRenderer`, cropped to the story's bounds. This works for both
  UIKit and SwiftUI. Use `layer.render(in:)` as a fallback for very tall
  content, and tile around the 8192 px limit, as Playbook and SnapshotPreviews
  do
  ([View+Snapshot.swift](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/SnapshotPreviewsCore/View%2BSnapshot.swift#L113-L192)).
- **Avoid `ImageRenderer` as the general path.** It replaces "most types of
  UIKit and AppKit views" and layer-composited views with placeholders
  ([docs](https://developer.apple.com/documentation/swiftui/imagerenderer)).
- **Full-fidelity capture:** `simctl io <dev> screenshot -`, or
  `devicectl device capture screenshot`, captures the real framebuffer
  (status bar, keyboard, alerts). Call it after the app reports settled.
- **Batch runs** (`storybook snapshot`):
  - Render stories sequentially in **one** app process and **one** reused
    window, which is far faster than one launch per story.
  - Shard across cloned simulators (`simctl clone`) for parallelism.
  - SnapshotPreviews instead generates one XCTest per preview at runtime, by
    swizzling `testInvocations` and adding a method per preview
    ([PreviewBaseTest.swift](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/SnapshottingTests/PreviewBaseTest.swift#L32-L100)).
    That gives Xcode test-navigator integration, and we should offer it as
    `StorybookXCTest` for CI. The CLI path doesn't need XCTest at all.

---

## 6. Communication between host and device/simulator

### 6.1 Channels

**Launch arguments and environment:**

- `simctl launch <dev> <bundle> -StorybookStory design-system-pay-button--primary -StorybookArgs '{"title":"Hi"}'`.
  Arguments like `-key value` land in the volatile argument domain of
  `UserDefaults`
  ([docs](https://developer.apple.com/documentation/foundation/userdefaults)).
- Environment variables use the `SIMCTL_CHILD_*` and `DEVICECTL_CHILD_*`
  prefixes (local `simctl help` and `devicectl help`, Xcode 27).
- **Pro:** stateless and always available.
- **Con:** fixed at launch.

**Deep links:**

- `simctl openurl <dev> storybook-<app>://story/<id>?args=…`, or the
  `devicectl … --payload-url` equivalent.
- **Pro:** changes the story without relaunching.
- **Cons:** one-way, and the first use may prompt **[unverified]**.

**Darwin notifications:**

- `devicectl device notification post` (Xcode 27) could serve as a "re-render"
  ping **[when introduced: unverified]**.
- Narrow use only.

**WebSocket, with the app as server:**

- An `NWListener` with `NWProtocolWebSocket` (iOS 13+,
  [docs](https://developer.apple.com/documentation/network/nwprotocolwebsocket)),
  with the CLI connecting to it.
- **Simulator:** it shares the Mac's network stack, so the CLI connects to
  `localhost:<port>`.
- **Device:** connect over USB with `iproxy <port> <port>`
  ([libusbmuxd](https://github.com/libimobiledevice/libusbmuxd); devicectl has
  no port forwarding) or over the LAN.
- **Local network privacy is the deciding factor.** TN3179 says the
  simulator doesn't apply local network privacy. On a device, **accepting
  incoming TCP doesn't require local-network access**, but connecting out to a
  LAN address and *any* Bonjour operation do
  ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
  So the app-as-server model works on a device with **no prompt**, as long as
  the host knows the device's address (from USB, devicectl, or a pasted or
  QR-coded address).
- **Prior art:** WebDriverAgent runs an HTTP server inside an XCTest runner on
  ports 8100–8199, which devices reach over usbmux
  ([WebDriverAgent](https://github.com/appium/WebDriverAgent)). SnapshotPreviews
  runs a FlyingFox HTTP server on loopback port 38824 inside the app, for its
  UI-test flow
  ([Snapshots.swift](https://github.com/EmergeTools/SnapshotPreviews/blob/aad18f047618db8a1380a9c0b94d027c574eb1b4/Sources/SnapshottingSwift/Snapshots.swift#L27)).

**WebSocket, with the app as client:**

- The app connects out to a server on the Mac.
- **Prior art:**
  - Pulse uses Bonjour with the Mac listening
    ([Pulse #142](https://github.com/kean/Pulse/discussions/142)).
  - Reactotron's app connects to `:9090`
    ([docs](https://docs.infinite.red/reactotron/troubleshooting/)).
  - React Native's Metro bakes the Mac's IP into the build
    ([RN docs](https://reactnative.dev/docs/running-on-device)).
  - InjectionNext connects to `127.0.0.1:8887`.
- **Pro:** easy on the simulator.
- **Cons on a device:** it needs the Mac's address and triggers the
  local-network prompt (plus `NSBonjourServices` if Bonjour is used).

**Bonjour (`_storybook._tcp`):**

- Optional discovery, so several devices can show up in the CLI or Mac app.
- On a device it needs `NSBonjourServices` and `NSLocalNetworkUsageDescription`,
  and triggers the prompt. Pulse's demo app broke when the key was missing
  ([CHANGELOG](https://github.com/kean/Pulse/blob/main/CHANGELOG.md)).
- Only useful for Wi-Fi devices.

### 6.2 "Render story X with args Y and give me a screenshot"

```text
agent ──MCP──▶ storybook daemon (Mac)
  1. ensure target: simctl boot / bootstatus; build if stale; simctl install
  2. ensure app: simctl launch --terminate-running-process … -StorybookAgentPort 9300
  3. connect ws://localhost:9300 (sim) | iproxy → ws://localhost:9300 (USB device)
  4. → {"id":7,"cmd":"renderStory","story":"design-system-pay-button--primary",
        "args":{"title":"Hi"},"globals":{"colorScheme":"dark"},"viewport":"iphone-16"}
  5. ← {"id":7,"ack":true}
  6. ← {"event":"storyRendered","story":…,"size":[343,52],"renderId":42}
  7. → {"id":8,"cmd":"snapshot","renderId":42,"mode":"element"}   // in-app drawHierarchy, cropped
     or daemon runs `simctl io <dev> screenshot -` for mode "device"
  8. ← {"id":8,"png":"<base64>"}  (or a file path when sim shares the Mac FS)
  9. MCP result: image + metadata (render time, warnings, actions fired)
```

- **This is the remote-command shape from Storybook 11.** Invoke, ack,
  result, with errors serialized back to the caller. Messages are `Codable`
  structs, which addresses "give messages schemas" from the architecture
  findings.
- **One authority.** The app is the authority for render state, and the daemon
  is a hub that forwards. That is enough until a Mac UI and an agent edit args
  concurrently. At that point, add version numbers per service as the
  findings doc suggests.
- **Delegated mode carries over:**
  - `storybook render …` attaches to a running daemon or app if it finds one,
    and otherwise boots, builds and launches.
  - `--attach` and `--no-attach` force either behaviour.
- **Agent prior art to align with:**
  - **[XcodeBuildMCP](https://github.com/cameroncooke/XcodeBuildMCP):** build,
    install, launch and logs; it may now live at getsentry/MobileBuildMCP
    **[unverified]**.
  - **[ios-simulator-mcp](https://github.com/joshuayoes/ios-simulator-mcp):**
    simctl plus idb for UI.
  - **[agent-device](https://github.com/callstackincubator/agent-device):** an
    accessibility bridge plus XCTest interactions, including physical devices.
  - **How to divide the work:** our daemon should handle story-level semantics
    (`renderStory`, `setArgs`, `listStories`, `snapshot`, `getActions`). Generic
    UI driving (tap, type, a11y tree) can come from those tools or from the
    in-app play-function runner, which is thread 04's area.

---

## 7. Recommended architecture

### 7.1 Components

| Component | Kind | Responsibility |
|---|---|---|
| `Storybook` | Swift library | Story format (thread 02): `Stories`, `StoryMeta`, `Story`, args, decorators. No UI. Safe to link into component modules. |
| `StorybookMacros` | Macro target | `@Stories`: generates `all`, validates literals, **emits a `@section("__DATA_CONST,__swift5_story") @used` record** (Swift ≥ 6.3). |
| `StorybookRuntime` | Swift library | Registry (section scan → conformance scan fallback → manual `register`), `StoryRenderer` (hosting, sizing, traits, isolation, settle, capture), event bus, **agent server** (`NWListener` WebSocket, typed RPC), launch-arg handling. |
| `StorybookUI` | Swift library | In-app browser: sidebar, canvas, Controls/Actions/a11y panels — built on runtime services. `StorybookScene` (model a) and `Storybook.present()` (model d). |
| `StorybookPreviewImport` | Optional library | `#Preview` importer via `PreviewRegistry` conformance scan + SPI shim. Off by default. |
| `StorybookXCTest` | Optional library | One XCTest per story for CI/snapshot pipelines. |
| `storybook` CLI | Swift executable on Mac | `init` (create host target), `index` (SwiftSyntax → `index.json`), `build`/`run`/`watch` (xcodebuild + simctl/devicectl + tier-1 reload), `render`/`snapshot`/`args` (toolsets), `mcp` (stdio MCP server), daemon with attach/no-attach. |
| `storybook-index` | Same binary as artifactbundle | Used by an optional build-tool plugin to regenerate `index.json` / `StoryRegistry.swift` on build. |
| Storybook.app (macOS) | Later | Toolset client UI; not required. |

### 7.2 Discovery order at runtime

1. **`__swift5_story` section records**, in all images that aren't system
   images. This is the fast path for macro users on Swift 6.3 and later.
2. **`__swift5_proto` conformances to `Storybook.Stories`.** This covers code
   without the macro, or older toolchains. Deduplicate against step 1 by type
   identity.
3. **Manual or generated `Storybook.register(...)` calls.** This is the
   escape hatch.
4. **Optionally, `#Preview` import.**

All of these feed one `StoryIndex` that has the same shape as the static
`index.json`. The runtime **compares** its index with the CLI's static index
and reports any drift, such as a story found at runtime that the static
indexer missed because a title wasn't a literal.

### 7.3 Diagram

```text
                       ┌──────────────────────── Mac ────────────────────────────┐
  user's sources ─────▶│ storybook CLI / daemon                                  │
  (*+Stories.swift)    │  ├─ index      SwiftSyntax ──▶ index.json (no build)    │
                       │  ├─ build/run  xcodebuild ─▶ simctl / devicectl         │
                       │  ├─ watch      FS events ─▶ tier1 rebuild+restore       │
                       │  │                         (tier2 injection, sim only)  │
                       │  ├─ toolsets   listStories renderStory setArgs snapshot │
                       │  │              getActions setGlobals …                 │
                       │  └─ surfaces   MCP (stdio) · CLI · Swift SDK · Mac app  │
                       └──────────┬──────────────────────────────┬───────────────┘
                 launch args /    │ WebSocket (typed RPC,        │ simctl io screenshot /
                 openurl          │ invoke→ack→result + events)  │ devicectl capture
                                  │ sim: localhost               │ (device-fidelity frames)
                                  │ device: iproxy (USB) or LAN  │
┌─────────────────────── iOS simulator / device ──────────────────▼───────────────┐
│ Host app  (a) <App>Storybook target   or   (d) user's Debug app + Storybook menu  │
│ ┌─────────────────────────────── StorybookRuntime ─────────────────────────────┐ │
│ │ Agent server (NWListener)  ◀──▶  Services: selection · args · globals ·      │ │
│ │                                  actions · render status                      │ │
│ │ Registry ◀── __swift5_story records ◀── @Stories macro                        │ │
│ │          ◀── __swift5_proto: Stories conformances                             │ │
│ │          ◀── manual/generated register()      ◀── (opt) #Preview importer     │ │
│ │ StoryRenderer: fresh UIHostingController / UIKit container                    │ │
│ │   → decorators (env + traitOverrides) → sizing mode → settle → drawHierarchy  │ │
│ └───────────────────────────────────────────────────────────────────────────────┘ │
│ StorybookUI (in-app browser + Controls/Actions panels)                            │
│ Linked modules: DesignSystem, PaymentsUI, … (components + their stories)          │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### 7.4 Why this shape

- **It works on devices.** Nothing loads code at runtime, and the app-as-server
  model avoids the local-network prompt over USB.
- **It needs no private API by default.** Private-API pieces (the `#Preview`
  import, injection, simulator embedding) are optional modules.
- **It degrades gracefully across toolchains:** section records on Swift 6.3+,
  conformance scanning everywhere, and manual registration as the floor.
- **It maps onto Storybook 11:**
  - the static and runtime index line up with `index.json`;
  - the daemon is the hub and the app is a leaf;
  - typed remote commands match services;
  - one toolset definition is exposed over MCP, the CLI and the SDK;
  - delegated mode carries over.

### 7.5 Open questions

- **Minimum toolchain.** Requiring Swift 6.3 lets `@section` be the only
  macro path. Otherwise we have to keep the conformance scanner as a
  first-class path. (Thread 02 asked this.)
- **Section name and kind.** Use our own section, or register a kind with
  Swift Testing and reuse `__swift5_tests` plus `_TestDiscovery`? An own
  section avoids the SPI dependency. Sharing one would let Swift Testing
  tooling see stories.
- **Creating the host target.** Edit `.pbxproj` with XcodeProj, generate a
  sidecar `Storybook.xcodeproj` or `Package.swift` app, or support Tuist and
  XcodeGen only?
- **Connecting to devices without libimobiledevice.** Options: a LAN address
  shown as a QR code in the app, devicectl tunnels (none exist yet), or
  bundling `iproxy`.
- **Tier 2 injection.** Integrate with InjectionNext, or skip it until Apple
  exposes anything?
- **Check before committing:**
  - `@used` records under Release `-dead_strip`;
  - whether a `simctl openurl` custom-scheme prompt appears;
  - Bonjour visibility from the simulator.
