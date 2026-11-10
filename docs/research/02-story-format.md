# 02 · Story format: how should stories be written in Swift?

Research thread 2 of 4. Question: **do we want a Swift version of CSF
(Component Story Format), and if so, what does it look like?** Read
[`../storybook-11-architecture-findings.md`](../storybook-11-architecture-findings.md)
first for project context.

> Researched October 2026 against Storybook `next` (11.0.0-alpha), Storybook
> docs for 10.x, Swift 6.3 and Xcode 16/26-era SwiftUI. Details marked
> "unverified" were not checked against source.

## TL;DR

- **Yes, a Swift CSF, but borrow its data model, not its syntax.** What makes
  CSF useful is the data model: one meta per file, named stories, args that
  merge (project → meta → story), argTypes, decorators, parameters, loaders,
  play functions, tags, and **ids derived from title + export name** so they
  stay stable. That model translates to Swift well. The JavaScript mechanics
  (ES module exports, object spreading, runtime evaluation) don't.
- **`#Preview` can't be the main format, but we should import it.** Third-party
  tools *can* find `#Preview` blocks: at runtime by scanning the Mach-O
  `__swift5_proto` section for `PreviewRegistry` conformances (EmergeTools'
  SnapshotPreviews does this), and statically with SwiftSyntax. But
  `#Preview` has no args, no play function, no tags, and often no name, so it
  can't give a story a stable id. Its runtime value can only be read through
  `Mirror` on a private struct. Import it as zero-effort, read-only stories.
- **Recommended format: a protocol-based "Stories" type plus an optional
  attached macro.** A file declares
  `enum ButtonStories: Stories { static let meta = …; static let primary = Story { … } }`.
  This is plain Swift that works with no macro. An optional `@Stories` macro
  generates the list of stories (Swift has no reflection over static members),
  records source locations, and **checks at compile time that titles, names,
  ids and tags are literals**, so a SwiftSyntax indexer can build
  `index.json` without compiling. This is the same contract the CSF indexer
  relies on.
- **Args are a `Codable` struct.** Controls are worked out from the property
  types (`String`, `Bool`, numbers, `CaseIterable` enums, `Optional`, a
  Codable colour type, an action type). Optional `@Arg(...)` wrappers override
  the control (range, multiline text, labels). `Codable` gives the
  "`setArgs` from JSON" path that the MCP toolset and host↔device protocol need,
  with nothing extra to write.
- **The manifest uses Storybook's shapes:** `index.json` v5 entries
  (`id`, `title`, `name`, `importPath`, `exportName`, `tags`, `type`) and an
  `argTypes` object per story that Storybook can read. Swift stays the source
  of truth, and JSON is generated from it. Authoring stories *in* JSON/YAML/CSF
  (option e) is a bad experience for iOS developers. Keep it only as a
  possible export target.

> **Update (Xcode 27):** the iOS 27.0 SDK adds `#Preview(_:traits:arguments: [T]) { (T) -> View }`
> (iOS 26+) and deprecates `PreviewProvider`. This gives `#Preview` a *static
> list of argument values*, so the importer can turn each value into a story.
> It still has no editable controls, no arg metadata, no play function and no
> stable per-value id, so the recommendation below stands. See
> [`README.md`](README.md).

---

## 1. CSF recap

### 1.1 CSF 3 (object stories)

A CSF file is an ES module. Its **default export** is the *meta*, and each
**named export** is a *story*
([docs](https://storybook.js.org/docs/api/csf)).

```ts
// Button.stories.ts
import type { Meta, StoryObj } from '@storybook/react';
import { Button } from './Button';

const meta = {
  title: 'Design System/Button',     // optional; auto-derived from file path if omitted
  component: Button,                 // drives docgen → argTypes inference
  args: { label: 'Pay', disabled: false },          // defaults for every story
  argTypes: { size: { control: 'select', options: ['s', 'm', 'l'] } },
  decorators: [(Story) => <Padding><Story /></Padding>],
  parameters: { layout: 'centered' },              // static, deep-merged config for addons
  loaders: [async () => ({ user: await fetchUser() })],
  tags: ['autodocs'],
} satisfies Meta<typeof Button>;
export default meta;
type Story = StoryObj<typeof meta>;

export const Primary: Story = {};                  // name "Primary"
export const Disabled: Story = {
  args: { disabled: true },
  play: async ({ canvas, userEvent }) => {         // runs after render
    await userEvent.click(canvas.getByRole('button'));
  },
};
export const LongLabel: Story = { name: 'Very long label', args: { label: '…' } };
```

The concepts:

| Concept | What it is | Merge rule |
| --- | --- | --- |
| **meta / default export** | `title`, `component`, `id`, plus defaults for everything below; `includeStories`/`excludeStories` filter which exports are stories | — |
| **named story exports** | each one is a story; the export name is its identity | — |
| **args** | serialisable inputs to the component, editable in Controls, set via URL/MCP | project → meta → story, shallow |
| **argTypes** | per-arg metadata: control type, options, range, description, category, `if` conditions | inferred from docgen, then overridden |
| **decorators** | wrappers `(Story, context) => …` | story innermost, then meta, then project |
| **parameters** | static, non-arg config for addons (layout, backgrounds, a11y rules…) | deep-merged |
| **loaders / `beforeEach`** | async setup before render; loaded data available to `render`/`play` | concatenated |
| **render** | custom render from args (default: `<Component {...args} />`) | story overrides meta |
| **play** | async interaction script after render, with `canvas`, `userEvent`, `expect` | — |
| **tags** | strings used for filtering and behaviour (`autodocs`, `dev`, `test`, `!dev` to remove) | combined; a `!tag` removes `tag` |
| **globals** | project-wide toolbar state (theme, locale, viewport) read by decorators | — |

### 1.2 CSF Next (formerly "CSF Factories")

CSF Next is a *preview* feature in Storybook 10.x
([docs](https://storybook.js.org/docs/api/csf/csf-next); earlier
[CSF Factories docs](https://storybook.js.org/docs/8/api/csf/csf-factories)).
The data model is the same. The difference is that stories come from chained
factories, so types flow through without annotations:

```ts
// .storybook/preview.ts
export default definePreview({ addons: [addonA11y()], decorators: [...] });

// Button.stories.ts
import preview from '#.storybook/preview';
const meta = preview.meta({ component: Button, args: { label: 'Pay' } });

export const Primary  = meta.story({});
export const Disabled = Primary.extend({ args: { disabled: true } }); // args shallow-merge,
                                                                      // parameters deep-merge,
                                                                      // decorators/tags concat
Disabled.test('is not clickable', async ({ canvas, userEvent }) => { … }); // experimental
```

Other API: `.input` (the raw annotations), `.composed` (the result after
merging with meta and preview), `.Component` and `.run()` (render or mount the
story from a test). This matters for Swift because **CSF Next is already
"typed values built from factories"**, and that maps onto Swift much more
naturally than CSF 3's untyped object literals. `definePreview` → `meta` →
`story` → `extend`/`test` is the shape we should copy.

### 1.3 How the index derives ids, titles and names

From `code/core/src/csf/csf-utils.ts`, `export-story.ts` and
`types/modules/indexer.ts` on `next`:

- **Title.** `meta.title` if present. Otherwise it's generated from the file
  path relative to the configured `stories` glob (autotitle). The indexer reads
  it **statically**, so it must be a string literal.
- **Name.** `story.name` if present. Otherwise
  `storyNameFromExport(exportName)`, which is start-case
  (`someNAME` → "Some NAME").
- **Id.** `toId(meta.id ?? title, storyNameFromExport(exportName))`
  (`csf-tools/CsfFile.ts`), so the id is
  `sanitize(title) + "--" + sanitize(startCase(exportName))`, e.g.
  `LoggedIn` → `--logged-in`. `sanitize` lowercases,
  turns punctuation and whitespace into `-`, collapses repeated dashes and
  trims them from the ends. `meta.id` replaces the title part, and
  `parameters.__id` replaces the whole id. **Renaming the display `name` does
  not change the id; renaming the export does.**
- **Tests.** `toTestId(storyId, testName)` → `storyId:sanitized-test-name`,
  indexed with `subtype: 'test'` and `parent`.
- **Tags.** `combineTags(project, meta, story)`. A tag starting with `!`
  removes that tag.

Index entry shape (`StoryIndex.v`=5, `entries: Record<id, IndexEntry>`):

```ts
type StoryIndexEntry = {
  type: 'story'; subtype: 'story' | 'test';
  id: string; name: string; title: string; importPath: string;
  tags?: string[]; exportName?: string; componentPath?: string;
  parent?: string; parentName?: string;   // tests only
};
type DocsIndexEntry = { type: 'docs'; id; name; title; importPath; tags?; storiesImports: string[] };
```

The index holds no args or argTypes. Those are computed by the preview after
it loads the file. For Swift this is a useful split: **the index can be built
statically from source, and argTypes can come from runtime.**

---

## 2. Swift building blocks

### 2.1 `#Preview`

```swift
#Preview("Primary", traits: .sizeThatFitsLayout) {
    PayButton(title: "Pay")
}
```

- **What it expands to** (Apple's closed-source `PreviewsMacros` plugin; you
  can see it with Xcode's "Expand Macro", roughly):

  ```swift
  @available(iOS 17.0, macOS 14.0, *)
  struct $s7MyApp…PreviewRegistryfMu_: DeveloperToolsSupport.PreviewRegistry {
      static let fileID = "MyApp/PayButton.swift"
      static let line = 42
      static let column = 1
      static func makePreview() throws -> DeveloperToolsSupport.Preview { … }
  }
  ```

  The type name is a compiler-generated unique name (`makeUniqueName`), so
  it changes as code moves around. `Preview`'s fields (`displayName`, `traits`,
  `source`) aren't public API.
- **Can third parties discover it? Yes, in two ways, both unofficial:**
  - *Runtime:* EmergeTools/Sentry
    [SnapshotPreviews](https://github.com/getsentry/SnapshotPreviews) walks
    every loaded image's `__TEXT,__swift5_proto` section, keeps conformances
    whose protocol is named `PreviewProvider` or `PreviewRegistry`, calls the
    type's metadata accessor, calls `makePreview()`, and then uses
    `Mirror(reflecting:).descendant("traits" / "displayName" / "source")` to
    get the view closure
    ([`ConformanceLookup.swift`](https://github.com/getsentry/SnapshotPreviews/blob/main/Sources/SnapshotPreviewsCore/ConformanceLookup.swift),
    [`SnapshotPreviewsCore.swift`](https://github.com/getsentry/SnapshotPreviews/blob/main/Sources/SnapshotPreviewsCore/SnapshotPreviewsCore.swift)).
    It works, and ships in production tooling, but it depends on private
    layout that could change in any Xcode release.
  - *Static:* [Prefire](https://github.com/BarredEwe/Prefire) parses source
    for `#Preview` and `PreviewProvider` blocks (Sourcery in older versions,
    its own parser in 5.x) and generates snapshot tests and a "playbook" view.
    The macro call is easy to find with SwiftSyntax. The name is usually a
    literal, but traits and the body can be any expression.
- **Ids.** SnapshotPreviews names snapshots `Module/File.swift:Display Name`
  and asks for display names to be unique per file. An unnamed preview only
  has `fileID:line`, which **changes whenever someone edits above it**.
- **Extension points Apple gives us (Xcode 16+):**
  - `PreviewModifier`: `static func makeSharedContext() async throws -> Context`
    plus `body(content:context:)`, applied with
    `#Preview(traits: .modifier(SampleData()))`. This is effectively a
    **decorator plus a loader**, cached across previews
    ([Apple docs](https://developer.apple.com/documentation/swiftui/previewmodifier),
    [Donny Wals](https://www.donnywals.com/using-previewmodifier-to-build-a-previewing-environment/)).
  - `@Previewable @State var x = …` inside the body, for local interactive
    state (SwiftUI only).
  - Custom `PreviewTrait` statics bundle traits but can't carry arbitrary
    metadata, beyond smuggling it inside a modifier value.
- **What's missing for our purposes:** args/controls, typed inputs, play
  functions, tags, docs metadata, guaranteed names, a public runtime API, and
  UIKit parity for `@Previewable`.

### 2.2 `PreviewProvider`

`struct Foo_Previews: PreviewProvider { static var previews: some View }`.
The conformance is public, so it's easy to find at runtime (same
`__swift5_proto` scan) and statically (`: PreviewProvider`). Several previews
in a `Group` are only separated by the private `_allPreviews`. DoorDash's
[PreviewSnapshots](https://github.com/doordash-oss/swiftui-preview-snapshots)
adds typed configurations on top:
`PreviewSnapshots<State>(configurations: [.init(name:state:)], configure: { state in View(state) })`,
shared between Xcode previews and snapshot tests. **This is the closest
existing Swift equivalent of "args + named stories"**, and its
`configure: (State) -> View` is CSF's `render(args)`.

### 2.3 Macros

- **Attached** (`@attached(member | peer | extension | memberAttribute |
  accessor | body)`) can add members to a type, add conformances, and inspect
  the declaration's syntax. That's ideal for "`@Stories` on a type → generate
  `allStories`, check literals, add a conformance".
- **Freestanding** (`#expr`, `#decl`). A `#Story { … }` at file scope must use
  `makeUniqueName`, because global-scope macros can't add arbitrary named
  declarations. That's why `#Preview` types have mangled names. Grouping
  stories into a meta then needs a convention (same file) or an explicit
  reference.
- **Diagnostics.** A macro can emit errors and fix-its, for example "title
  must be a string literal so the indexer can read it". That's the Swift
  version of the CSF indexer's static-analysis rules, enforced at compile time
  rather than when the index is built.
- **Costs.** The macro target depends on swift-syntax, which used to add
  minutes to clean builds. Recent SwiftPM can use prebuilt swift-syntax for
  macros, which removes most of that (check for the toolchain we target). Xcode
  shows a one-time "Trust & Enable" prompt for package macros. Macro expansion
  also runs in a sandboxed plugin process on every build of the file.
- **Runtime registration without reflection.** Swift has no way to enumerate
  static members of a type. The options are:
  1. **Protocol conformance scanning** (`__swift5_proto`, as
     SnapshotPreviews does). Works today, and our *own* protocol is public, so
     no private layout is involved.
  2. **Swift Testing-style content records.** SE-0492 `@section`/`@used`
     (**implemented in Swift 6.3**,
     [proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md))
     lets a macro emit a record into a named section. Swift Testing finds
     `@Test`s this way (`__DATA_CONST,__swift5_tests`). Its
     [TestContent ABI](https://github.com/swiftlang/swift-testing/blob/main/Documentation/ABI/TestContent.md)
     explicitly invites **third-party record kinds** (Apple's experimental
     `#Playground` uses kind `'play'`) and provides a `_TestDiscovery` module
     for enumerating them. A `#Story`/`@Stories` macro could reserve a kind such
     as `'stry'`.
  3. **Explicit registration** (`Storybook.register(ButtonStories.self)`, or
     a generated `AllStories.swift` from a build plugin). Boring and reliable,
     and a good fallback.

### 2.4 Result builders

These give DSL syntax for lists (`StoryGroup { Story(…); Story(…) }`), the
way Playbook does it. The downsides are type erasure of heterogeneous `some
View`s, slower type-checking for large bodies (the `ViewBuilder` problem), no
per-story *symbol* to use as a stable export name, and no compile-time
uniqueness checks.

### 2.5 Property wrappers, `@Observable`, `Codable`, associated types

- **Property wrappers** (`@Arg(.range(0...5)) var rating = 3.0`) carry
  per-field control metadata. `Mirror` shows them as `_rating` children, so
  runtime argType extraction works without macros.
- **`Codable`** gives args a wire format. Host/MCP `setArgs(json)` becomes:
  encode the current args → merge the JSON patch → decode. No key paths, no
  hand-written schema. `Color` isn't `Codable`, so we need a small `StoryColor`
  (hex/RGBA) type.
- **`@Observable`.** The runtime keeps the *current* args in an observable box,
  so editing a control re-renders only that story. Authors never see it.
- **Protocols with associated types.** `protocol Stories { associatedtype
  Args: StoryArgs; static var meta: StoryMeta<Args> { get } }` ties a file's
  stories to one args type. That's the Swift version of `Meta<typeof Button>`.
  Caseless `enum`s work well as namespaces because they can't be instantiated
  and static stored properties are allowed on them (not on generic types).

---

## 3. Prior art

| Project | Platform | Authoring | Discovery | Args/controls | Notes |
| --- | --- | --- | --- | --- | --- |
| [Storybook CSF](https://storybook.js.org/docs/api/csf) / [CSF Next](https://storybook.js.org/docs/api/csf/csf-next) | Web/RN | ES module exports / factories | static indexer (Babel) | args + argTypes, docgen inference | the reference model |
| [SnapshotPreviews](https://github.com/getsentry/SnapshotPreviews) | iOS | `#Preview` / `PreviewProvider` unchanged | runtime `__swift5_proto` scan + `Mirror` | none | `PreviewGallery` in-app browser; ids = `File.swift:Display Name` |
| [Prefire](https://github.com/BarredEwe/Prefire) | iOS | `#Preview` + `.prefireIgnored()` / `.previewUserStory(...)` modifiers | static source parsing → codegen (build plugin) | none | metadata via no-op view modifiers |
| [PreviewSnapshots](https://github.com/doordash-oss/swiftui-preview-snapshots) (DoorDash) | iOS | `PreviewSnapshots<State>(configurations:configure:)` | manual (`PreviewProvider` static) | typed state, no UI controls | closest to "typed args + named stories" |
| [Playbook](https://github.com/playbook-ui/playbook-ios) | iOS | `Scenario("Name", layout:) { … }` inside `addScenarios(of: "Kind")`, `ScenarioProvider` | explicit registration | none | snapshot runner, gallery/catalog UI; `ScenarioContext.snapshotWaiter` ≈ async readiness |
| [Storybook-SwiftUI](https://github.com/aj-bartocci/Storybook-SwiftUI) | iOS | `extension Storybook { @objc static let x = StorybookPage(folder:views:) }` | ObjC runtime reflection over `@objc` statics | environment-based controls (dark mode, font size, custom) | folders ≈ titles; v2.1 adds tags |
| [Showkase](https://github.com/airbnb/Showkase) (Airbnb) | Android | `@Preview` or `@ShowkaseComposable(name, group, styleName, …)`, `@ShowkaseColor`, `@ShowkaseTypography`, `@ShowkaseRoot` | KSP/kapt annotation processing → generated registry | via `@PreviewParameter` | browser shows dark mode, RTL, font scale variants per component ([InfoQ](https://www.infoq.com/news/2020/12/airbnb-showkase-jetpack-compose/)) |
| [Compose previews](https://developer.android.com/jetpack/compose/tooling/previews) | Android | `@Preview(name, group, uiMode, fontScale, locale, device…)`; multipreview annotation classes (`@PreviewLightDark`, `@PreviewFontScale`, `@PreviewScreenSizes`) | IDE / annotation processors | `@PreviewParameter(Provider::class)` with `PreviewParameterProvider<T>.values: Sequence<T>` → one preview per value | multipreview annotations = **reusable decorator matrices** |
| [Widgetbook](https://docs.widgetbook.io/knobs/overview) | Flutter | `@UseCase(name:, type: Button)` on a builder function | `build_runner` codegen | **knobs** read inside the builder: `context.knobs.string(label:, initialValue:)`, `stringOrNull`, `double.slider`, custom knobs | knobs are declared at render time, so they can't be indexed statically |

What we take from these:

1. Every successful native tool **builds on what developers already write**
   (`@Preview`, `#Preview`) *or* gives them one clear place to declare stories
   with a code-generation/registry step. Reflection-only tricks (ObjC statics,
   `Mirror` on private types) work, but they're fragile.
2. Typed inputs come in three forms: a *state value + configure closure*
   (PreviewSnapshots), a *parameter provider* (Compose), or *knobs read during
   render* (Widgetbook). Only the first is both typed and statically known
   ahead of render.
3. Environment variants (dark mode, RTL, font scale) are handled as
   **project-level matrices/globals**, not per-story code. In Storybook terms
   they're globals plus decorators.

---

## 4. Candidate formats

The running example is a `PayButton(title:style:isEnabled:rating:tint:badge:onTap:)`.

### Shared args model (used by b, c, d)

```swift
enum PayButtonStyle: String, Codable, CaseIterable { case primary, secondary, destructive }

struct PayButtonArgs: StoryArgs {               // StoryArgs = Codable & Sendable & Equatable
    var title = "Pay"                          // → text
    var style: PayButtonStyle = .primary       // → select [primary, secondary, destructive]
    var isEnabled = true                       // → boolean
    @Arg(.range(0...5, step: 0.5)) var rating = 3.0   // → range slider
    var tint: StoryColor = .hex("#0A84FF")     // → color
    var badge: Int? = nil                      // → number + "nil" toggle
    @Arg(.text(multiline: true), description: "Shown under the title")
    var footnote = ""
    var onTap = StoryAction("onTap")           // → Actions panel; Codable as its name
}
```

How controls are derived (runtime: `Mirror` over a default instance plus
`ArgValue` conformances; static: the SwiftSyntax scanner reads stored
properties):

| Swift type | Control | Storybook `argTypes` |
| --- | --- | --- |
| `String` | text (`@Arg(.text(multiline:))`) | `{ control: 'text' }` |
| `Bool` | toggle | `{ control: 'boolean' }` |
| `Int`, `Double`, `CGFloat` | number; `@Arg(.range(…, step:))` → slider | `{ control: { type: 'range', min, max, step } }` |
| `enum: CaseIterable & RawRepresentable & Codable` | select/segmented | `{ control: 'select', options: [...] }` |
| `Optional<T>` | T's control plus a "nil" switch | `{ control: …, type: { required: false } }` |
| `StoryColor` | colour picker | `{ control: 'color' }` |
| `Date` | date picker | `{ control: 'date' }` |
| `StoryAction` | none; calls are logged | `{ action: 'onTap' }` |
| any other `Codable` | JSON object editor | `{ control: 'object' }` |

### (a) Reuse `#Preview` as-is

```swift
#Preview("Primary", traits: .sizeThatFitsLayout) { PayButton(title: "Pay") }

#Preview("Disabled", traits: .modifier(StorybookDecorators.dark)) {
    PayButton(title: "Pay", isEnabled: false)
}

#Preview("Interactive") {                 // local state only, no external controls
    @Previewable @State var rating = 3.0
    PayButton(title: "Pay", rating: rating)
}
```

| Aspect | Assessment |
| --- | --- |
| Typed args / controls | **None.** `@Previewable @State` is local; Xcode's canvas variants cover colour scheme, orientation and Dynamic Type only |
| Decorators | `PreviewModifier` via `.modifier(...)` trait; works well for environment/data |
| Play | none |
| Docs metadata | none, apart from doc comments near the macro |
| Stable ids | `fileID + displayName`; **unnamed previews have no stable id** (`line` changes) |
| Ergonomics | best possible: developers already write these, and Xcode canvas works |
| Compile cost | none for us |
| Static discovery | easy to find the macro call; traits are arbitrary expressions |
| Runtime discovery | `__swift5_proto` scan + `Mirror` on private `Preview` layout (fragile) |
| `index.json` mapping | title = file name start-cased (or `Module/File`), name = display name, id = `sanitize(title)--sanitize(name)`, `tags: ['preview']` |

**Verdict:** support it as an import source, not as the primary format.

### (b) Protocol-based `Stories` type, static members (CSF Next in Swift)

```swift
import Storybook

enum PayButtonStories: Stories {
    static let meta = StoryMeta(
        title: "Design System/Pay Button",       // optional; default: "<Module>/PayButton"
        component: PayButton.self,              // for docs: symbol graph, source link
        args: PayButtonArgs(),
        decorators: [.padding(), .background(.secondarySystemBackground)],
        parameters: [.layout(.centered)],
        tags: ["autodocs"]
    ) { args in                                 // default render(args), like CSF's component render
        PayButton(args)
    }

    static let primary = meta.story()

    static let disabled = primary.extend(name: "Disabled state") {
        $0.isEnabled = false
    }

    static let longTitle = meta.story(args: { $0.title = "Pay £1,234.56 with Apple Pay" },
                                      parameters: [.layout(.fill)])

    static let rtl = meta.story(globals: [.layoutDirection(.rightToLeft), .locale("ar")])

    static let tapsOnce = meta.story(
        play: { ctx in
            try await ctx.tap(.button("Pay"))
            try ctx.expectAction("onTap", calledTimes: 1)
        }
    )

    // Without the macro, list the stories once (Swift can't enumerate statics):
    static let all: [StoryEntry] = [
        .init("primary", primary), .init("disabled", disabled),
        .init("longTitle", longTitle), .init("rtl", rtl), .init("tapsOnce", tapsOnce),
    ]
}
```

UIKit uses the same shape: `StoryMeta(…) { args in PayButtonView(args) as UIView }`
or `{ args in PayViewController(args) as UIViewController }`. Overloads wrap
them in representables.

| Aspect | Assessment |
| --- | --- |
| Typed args / controls | strong: `Args` is the associated type, `extend { $0.x = … }` is type-checked |
| Decorators | `StoryDecorator` values (environment, colorScheme, dynamicType, locale, device frame); project → meta → story order like CSF |
| Play | `@MainActor (PlayContext<Args>) async throws -> Void` |
| Docs metadata | `///` doc comments on the type/members (SwiftSyntax/symbol graph) plus `description:` |
| Stable ids | `sanitize(title)--sanitize(startCase(memberName))` (`longTitle` → `--long-title`); `id:` overrides; renaming `name:` doesn't change the id, exactly as in CSF |
| Ergonomics | good; the `all` list is the main annoyance (fixed by c) |
| Compile cost | low; plain generics, no swift-syntax |
| Static discovery | good **if** title/name/tags are literals (a convention, not enforced) |
| Runtime discovery | `__swift5_proto` scan for **our own public `Stories` protocol**, which is robust |
| `index.json` mapping | 1:1 with CSF: `exportName` = member name, `importPath` = `fileID` |

### (c) Macro-based: `@Stories` (attached) and/or `#Story` (freestanding)

**c1. Attached macro on the (b) type.** Same code as (b), minus the
hand-written `all`:

```swift
@Stories(title: "Design System/Pay Button", tags: ["autodocs"])
enum PayButtonStories {
    static let meta = StoryMeta(args: PayButtonArgs()) { PayButton($0) }

    /// The default call to action.
    static let primary = meta.story()
    static let disabled = primary.extend(name: "Disabled state") { $0.isEnabled = false }
}

// Expansion (sketch):
extension PayButtonStories: Stories {
    static let __title = "Design System/Pay Button"
    static let __tags: [String] = ["autodocs"]
    static var all: [StoryEntry] {[
        StoryEntry("primary", primary, docs: "The default call to action.",
                   fileID: #fileID, line: 6),
        StoryEntry("disabled", disabled, fileID: #fileID, line: 7),
    ]}
}
// + optional (Swift 6.3): @section("__DATA_CONST,__swift5_tests") @used record of kind 'stry'
```

What the macro adds over (b):

- generates `all` from `static let` members whose type is `Story<…>`, so the
  member name becomes the export name;
- reports compile errors for non-literal `title`/`name`/`id`/`tags`, duplicate
  ids, and story names that sanitize to empty;
- captures `///` docs and source lines for the docs panel and "open in Xcode";
- optionally emits a discovery record (see §2.3), so we don't need the
  conformance scan.

**c2. Freestanding `#Story`, modelled on `#Preview`:**

```swift
private let meta = StoryMeta(title: "Design System/Pay Button", args: PayButtonArgs())

#Story("Primary", meta: meta) { args in PayButton(args) }
#Story("Disabled", meta: meta, args: { $0.isEnabled = false }) { args in PayButton(args) }
```

This feels familiar to anyone who knows `#Preview`. But there's no member
name, so **the display name doubles as the id**: renaming a story changes
its URL (unless `id:` is given). File-scope macros can only produce
unique-named types, and the meta link depends on a variable reference that the
macro can't resolve, so the static indexer has to match `meta:` by name within
the file.

| Aspect | c1 `@Stories` | c2 `#Story` |
| --- | --- | --- |
| Typed args | as (b) | as (b), via `meta`'s generic |
| Stable ids | member name (CSF-like) | display string (or explicit `id:`) |
| Ergonomics | best for files with several stories | best for one-off stories; feels like `#Preview` |
| Compile cost | swift-syntax dependency + expansion; small per file | same |
| Static discovery | **guaranteed**: the macro enforces literals | good; meta link is by-name convention |
| Runtime discovery | conformance or section record | section record (or unique-type conformance scan) |

### (d) Result-builder DSL

```swift
let payButtonStories = StoryGroup("Design System/Pay Button", args: PayButtonArgs()) {
    Story("Primary")
    Story("Disabled") { $0.isEnabled = false }
    Story("Dark", decorators: [.colorScheme(.dark)])
    Story("Taps once", play: { try await $0.tap(.button("Pay")) })
} render: { args in
    PayButton(args)
}

// somewhere: Storybook.register(payButtonStories)   — or scan for `StoryGroup` globals statically
```

| Aspect | Assessment |
| --- | --- |
| Typed args | good (the group's generic `Args`) |
| Decorators / play | as (b) |
| Stable ids | from string names; renaming changes the id unless `id:` |
| Ergonomics | compact and familiar (Playbook-like); nice for long variant lists |
| Compile cost | result-builder type-checking grows with story count; diagnostics inside builders are poor |
| Static discovery | weaker: names must be literals inside builder closures; globals need registration |
| Runtime discovery | needs explicit registration (global `let`s aren't enumerable) |
| `index.json` mapping | works, but `exportName` is synthetic |

### (e) External file (JSON/YAML) or CSF-compatible source

```yaml
# PayButton.stories.yaml
title: Design System/Pay Button
component: PayButton            # Swift type; must have init(args: PayButtonArgs) or memberwise Decodable args
args: { title: Pay, style: primary, isEnabled: true }
argTypes: { rating: { control: { type: range, min: 0, max: 5, step: 0.5 } } }
tags: [autodocs]
stories:
  Primary: {}
  Disabled: { name: Disabled state, args: { isEnabled: false } }
```

A build plugin turns this into (b)-style Swift. The CSF-compatible version is a
real `.stories.ts` whose `component` is a string id rendered by a custom
renderer that talks to the device (similar to how Storybook's old "server"
renderer used JSON stories).

| Aspect | Assessment |
| --- | --- |
| Typed args | only after codegen; typos show up as build errors in generated code |
| Decorators / play | only by name (`decorators: [darkMode]`) referencing Swift-registered ones; play would be JS or nothing |
| Stable ids | excellent (pure data) |
| Ergonomics | **poor for iOS developers**: two languages, no autocomplete against Swift types, no Xcode canvas |
| Compile cost | build plugin codegen (cheap) |
| Static discovery | trivial |
| Web Storybook | native fit: the files *are* the index |

**Verdict:** don't use this as the authoring format. Get web-Storybook interop
by *exporting* `index.json` + `argTypes` from Swift (§5.4), and leave room for
an optional custom indexer in Storybook's Node server (option B in the
architecture doc) that reads our manifest.

### (f) Variant worth noting: Widgetbook-style knobs

```swift
static let playground = meta.story { ctx in
    PayButton(title: ctx.arg("title", default: "Pay"),
              rating: ctx.arg("rating", default: 3.0, .range(0...5)))
}
```

It's quick to write and needs no args struct, but argTypes only exist *after a
render*, the names are untyped strings, and it can't be indexed statically. At
most, allow it as an escape hatch for a "playground" story.

### Comparison summary

| | (a) `#Preview` | (b) protocol | (c1) `@Stories` | (c2) `#Story` | (d) builder | (e) external |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| Typed args + derived controls | ✗ | ✓ | ✓ | ✓ | ✓ | ~ |
| Decorators | ~ (`PreviewModifier`) | ✓ | ✓ | ✓ | ✓ | ~ |
| Play functions | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ |
| Stable CSF-style ids | ✗ | ✓ | ✓ | ~ | ~ | ✓ |
| Static discovery reliability | ~ | ~ | ✓ (enforced) | ✓ | ~ | ✓ |
| Runtime discovery robustness | ✗ (private layout) | ✓ | ✓ | ✓ | ~ (registration) | ✓ |
| Works without macros | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ |
| Compile cost | none | low | medium (swift-syntax) | medium | medium (type-checker) | low |
| Familiarity | ★★★ | ★★ | ★★ | ★★★ | ★★ | ★ |
| Maps to `index.json` | ~ | ✓ | ✓ | ✓ | ✓ | ✓ |

---

## 5. Cross-cutting design notes

### 5.1 Decorators and globals

```swift
public protocol StoryDecorator: Sendable {
    associatedtype Body: View
    @MainActor func body(content: StoryContent, context: StoryContext) -> Body
}
```

Built in: `.colorScheme(_)`, `.dynamicType(_)`, `.locale(_)`,
`.layoutDirection(_)`, `.environment(\.key, value)`, `.padding()`,
`.background(_)`, `.deviceFrame(.iPhone16Pro)`, `.navigationStack`,
`.modifier(somePreviewModifier)` (which reuses existing `PreviewModifier`s and
their shared context). Order follows CSF: story decorators sit innermost, then
meta, then project.

**Globals** (colour scheme, Dynamic Type, locale, RTL, device) are host
toolbar state, not story code. A project-level decorator applies them, as
`definePreview` does. Compose-style matrices (light/dark × font scales)
become a **global axis**, and the snapshot/test runner expands it. Stories
shouldn't repeat it.

### 5.2 Loaders

```swift
static let withUser = meta.story(load: { try await Fixtures.user() }) { args, user in
    ProfileHeader(user: user, compact: args.compact)
}
```

This is a typed equivalent of CSF `loaders`/`beforeEach`. Shared expensive
setup (a SwiftData container) can use a cached project-level loader, matching
`PreviewModifier.makeSharedContext`.

### 5.3 Play functions

`play: @MainActor (PlayContext<Args>) async throws -> Void`. `PlayContext`
gives access to `args` (read and write), the action log, element queries by
accessibility identifier, label or role, and `expect`. *How* a tap gets
performed (in process through accessibility activation, or through XCUITest
from the host) belongs to the runtime/automation threads. The format only
fixes the signature, so the play body stays the same whichever driver runs it.
Named tests on a story (`Disabled.test('…')` in CSF Next) map to
`story.test("is not clickable") { ctx in … }`, indexed as
`subtype: "test"`, `id: "<storyId>:is-not-clickable"`.

### 5.4 Manifest and `index.json`

The static indexer (SwiftSyntax, no build) produces Storybook-shaped entries:

```json
{
  "v": 5,
  "entries": {
    "design-system-pay-button--disabled": {
      "type": "story", "subtype": "story",
      "id": "design-system-pay-button--disabled",
      "title": "Design System/Pay Button",
      "name": "Disabled state",
      "importPath": "PaymentsUI/PayButton+Stories.swift",
      "exportName": "disabled",
      "componentPath": "PaymentsUI/PayButton.swift",
      "tags": ["dev", "test", "autodocs"]
    }
  }
}
```

The runtime manifest, produced by the app at launch and served by the toolset
(`listStories`, `getArgTypes`), adds `argTypes` and the initial `args` in
Storybook's shapes. Swift-specific data (module, line, story kind
SwiftUI/UIView/UIViewController, Swift type names) goes under a namespaced key
such as `"x-ios": {…}`, so Storybook-aware agents and tools can still read
the standard fields. `sanitize`, `toId`, `storyNameFromExport` and
`combineTags` should be ported **exactly**, with Storybook's own test
vectors, so ids match across both worlds.

### 5.5 Where stories live

Stories need `internal` access to views and fixtures, so by default they go in
the component's module, in a `*+Stories.swift` file next to the component,
gated by `#if STORYBOOK` (or `DEBUG`) so Release builds strip them. A separate
`FooStories` target that uses `@testable import` is the alternative for teams
that keep production modules clean. The format works the same either way,
because `importPath` is the `fileID`.

---

## 6. Recommendation

**Use (b) as the core, add (c1) as optional sugar, import (a), and export to
Storybook's shapes.**

1. **Core, no macros:** `Stories` protocol, `StoryMeta<Args>`, `Story<Args>`,
   `StoryArgs` (`Codable`), `@Arg`, `StoryDecorator`, `PlayContext`. Teams
   that won't adopt macros can still write stories, and runtime discovery
   uses a robust scan of conformances to our own protocol.
2. **`@Stories` macro (recommended default in templates):** generates `all`,
   enforces literals so the static index is always correct, captures docs and
   source locations, and on Swift 6.3+ can emit a section record for
   discovery. `#Story` (c2) can come later for people who want a
   `#Preview`-like experience. It costs little once the core exists.
3. **`#Preview` importer:** both a runtime scan (behind a feature flag, since
   it relies on private layout) and a static scan. These become read-only
   stories tagged `preview`, titled from `fileID`, with ids from the display
   name. Unnamed previews show a warning in the index because their id isn't
   stable.
4. **Ids and index:** port Storybook's id rules exactly and emit `index.json`
   v5. Don't support external YAML/CSF authoring for now.

### Minimal API sketch

```swift
// MARK: Args
public protocol StoryArgs: Codable, Sendable, Equatable { init() }

@propertyWrapper
public struct Arg<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var wrappedValue: Value
    public let control: ArgControl?        // not encoded; read via Mirror
    public let description: String?
    public init(wrappedValue: Value, _ control: ArgControl? = nil, description: String? = nil)
}

public enum ArgControl: Sendable, Equatable {
    case text(multiline: Bool = false)
    case range(ClosedRange<Double>, step: Double = 1)
    case select, segmented, radio
    case color, date, object
    case hidden
}

public struct StoryColor: Codable, Sendable, Equatable { public static func hex(_: String) -> Self }
public struct StoryAction: Codable, Sendable, Equatable {        // encodes as its name
    public init(_ name: String)
    public func callAsFunction(_ payload: (any Sendable)...)     // logs to the Actions panel
}

// MARK: Meta & stories
public struct StoryMeta<Args: StoryArgs>: Sendable {
    public init<V: View>(
        title: String? = nil, id: String? = nil,
        component: Any.Type? = nil,
        args: Args = .init(),
        decorators: [AnyStoryDecorator] = [],
        parameters: StoryParameters = [],
        tags: [String] = [],
        @ViewBuilder render: @escaping @MainActor (Args) -> V
    )
    public func story(
        name: String? = nil, id: String? = nil,
        args: (inout Args) -> Void = { _ in },
        decorators: [AnyStoryDecorator] = [],
        globals: StoryGlobals = [],
        parameters: StoryParameters = [],
        tags: [String] = [],
        play: (@MainActor (PlayContext<Args>) async throws -> Void)? = nil
    ) -> Story<Args>
}

public struct Story<Args: StoryArgs>: Sendable {
    public func extend(name: String? = nil, _ args: (inout Args) -> Void = { _ in },
                       /* same optional overrides as story(...) */) -> Story<Args>
    public func test(_ name: String,
                     _ body: @escaping @MainActor (PlayContext<Args>) async throws -> Void) -> Story<Args>
}

// MARK: Files
public protocol Stories {
    associatedtype Args: StoryArgs
    static var meta: StoryMeta<Args> { get }
    static var all: [StoryEntry] { get }          // generated by @Stories
}

@attached(extension, conformances: Stories, names: named(all), named(__title), named(__tags))
public macro Stories(title: String? = nil, id: String? = nil, tags: [String] = [])
    = #externalMacro(module: "StorybookMacros", type: "StoriesMacro")

// MARK: Project-level (≈ definePreview)
public protocol StorybookConfiguration {
    static var decorators: [AnyStoryDecorator] { get }
    static var globalTypes: [GlobalType] { get }   // colorScheme, dynamicType, locale, device…
    static var tags: [String] { get }
}
```

Usage:

```swift
#if STORYBOOK
import Storybook

@Stories(title: "Design System/Pay Button", tags: ["autodocs"])
enum PayButtonStories {
    static let meta = StoryMeta(args: PayButtonArgs(), decorators: [.padding()]) { PayButton($0) }

    static let primary  = meta.story()
    static let disabled = primary.extend(name: "Disabled state") { $0.isEnabled = false }
    static let tapsOnce = meta.story(play: { ctx in
        try await ctx.tap(.button("Pay"))
        try ctx.expectAction("onTap", calledTimes: 1)
    })
}
#endif
// ids: design-system-pay-button--primary, --disabled, --taps-once
```

### Open questions for the other threads

- **Runtime thread:** which discovery mechanism should be primary, the
  conformance scan or `@section` records? That depends on the minimum Swift
  version we support.
- **Automation thread:** what does `PlayContext.tap` use (in-process
  accessibility or host XCUITest)? The format only fixes the signature.
- **Host/protocol thread:** `setArgs` takes a JSON merge patch over `Codable`
  args. Confirm that this fits the patch-based sync model.

## Sources

- Storybook CSF: <https://storybook.js.org/docs/api/csf>
- Storybook CSF Next: <https://storybook.js.org/docs/api/csf/csf-next>; CSF Factories (v8): <https://storybook.js.org/docs/8/api/csf/csf-factories>
- Storybook source (`next`): `code/core/src/csf/csf-utils.ts` (`sanitize`, `toId`, `toTestId`, `combineTags`), `code/core/src/csf/export-story.ts` (`storyNameFromExport`), `code/core/src/types/modules/indexer.ts` (`IndexInput`, `StoryIndexEntry`): <https://github.com/storybookjs/storybook/tree/next/code/core/src>
- SnapshotPreviews: <https://github.com/getsentry/SnapshotPreviews> (registry listing: <https://swiftpackageregistry.com/EmergeTools/SnapshotPreviews>)
- Prefire: <https://github.com/BarredEwe/Prefire>, <https://swiftpackageregistry.com/BarredEwe/Prefire>
- PreviewSnapshots (DoorDash): <https://github.com/doordash-oss/swiftui-preview-snapshots>
- Playbook: <https://github.com/playbook-ui/playbook-ios>
- Storybook-SwiftUI: <https://github.com/aj-bartocci/Storybook-SwiftUI>
- Apple `PreviewModifier`: <https://developer.apple.com/documentation/swiftui/previewmodifier>; adding previews: <https://developer.apple.com/documentation/xcode/adding-previews-to-your-interface-files>; Donny Wals on `PreviewModifier`: <https://www.donnywals.com/using-previewmodifier-to-build-a-previewing-environment/>
- SE-0492 Section Placement Control: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0492-section-control.md>, review <https://forums.swift.org/t/se-0492-section-placement-control/82289>
- Swift Testing test content ABI: <https://github.com/swiftlang/swift-testing/blob/main/Documentation/ABI/TestContent.md>
- Swift macros: SE-0382, SE-0389, SE-0397, SE-0402, SE-0415 in <https://github.com/swiftlang/swift-evolution/tree/main/proposals>
- Showkase: <https://github.com/airbnb/Showkase>, <https://www.infoq.com/news/2020/12/airbnb-showkase-jetpack-compose/>
- Compose previews, multipreview and `PreviewParameterProvider`: <https://developer.android.com/jetpack/compose/tooling/previews>, <https://developer.android.com/reference/kotlin/androidx/compose/ui/tooling/preview/package-summary>
- Widgetbook knobs: <https://docs.widgetbook.io/knobs/overview>
