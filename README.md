# iOS Storybook

A native storybook for SwiftUI and UIKit components, built on Storybook's
ideas (CSF-style stories, args and controls, globals, actions, agent
toolsets) without Storybook's web stack. This is a first spike; see
[`docs/research/`](docs/research/README.md) for the research and decisions
behind it, and [`docs/spike.md`](docs/spike.md) for what the spike proved.

## Writing stories

Put a `+Stories.swift` file next to the component, inside `#if STORYBOOK`:

```swift
#if STORYBOOK
import Storybook

struct PayButtonArgs: StoryArgs {
    var title = "Pay"
    var style: PayButtonStyle = .primary   // CaseIterable enum → select control
    var isEnabled = true                   // → toggle
    var tint: StoryColor = .hex("#0A84FF") // → color picker
    var onTap = StoryAction("onTap")       // → logged in the Actions panel
}

enum PayButtonStories: Stories {
    static let meta = StoryMeta(title: "Design System/Pay Button", args: PayButtonArgs()) { args in
        PayButton(args.title, style: args.style, isEnabled: args.isEnabled,
                  tint: args.tint.color, action: args.onTap.handler)
    }

    static let primary = meta.story()
    static let disabled = primary.extend(name: "Disabled state") { $0.isEnabled = false }

    static var all: [StoryEntry<PayButtonArgs>] {
        [.init("primary", primary), .init("disabled", disabled)]
    }
}
#endif
```

- Story ids follow Storybook's rules exactly: `design-system-pay-button--disabled`.
  They come from the member name, so renaming the display name doesn't change the id.
- `@Arg(.range(0...5, step: 0.5))`, `@Arg(.text(multiline: true))` and `@Arg(.hidden)` override controls.
- `StoryMeta.uiView(args:) { args in MyUIView(...) }` declares UIKit stories.
- Layouts: `.centered` (default), `.padded`, `.fullscreen`.
- `Stories` types are found at runtime by scanning Swift conformance records.
  There is nothing to register. `StoryRegistry.register(...)` is the escape hatch.

## Running the example

Requires Xcode 27 (Swift 6.3+), iOS 18+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd Examples/StorybookHost
xcodegen generate
xcodebuild -project StorybookHost.xcodeproj -scheme StorybookHost \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/StorybookHost.app
xcrun simctl launch booted dev.storybook.host
```

The `StorybookHost` app is a sidecar project. It links the
`SampleDesignSystem` package and contains only `StorybookScene()`.

Launch arguments restore state after a rebuild:
`-StorybookStory <id> -StorybookArgs '<json>' -StorybookGlobals '{"colorScheme":"dark"}'`.

## Driving it from the CLI or an agent

```bash
swift build --product storybook
.build/debug/storybook list
.build/debug/storybook stories render design-system-pay-button--primary \
  --args '{"title":"Pay £42","style":"secondary"}' --globals '{"colorScheme":"dark"}' --out pay.png
# captures keep a 16 pt margin for shadows; --bleed 0 crops to the component
.build/debug/storybook args set design-system-pay-button--primary --args '{"isLoading":true}'
.build/debug/storybook actions list
.build/debug/storybook mcp        # stdio MCP server with the same tools
```

Each toolset method is defined once, in `Sources/StorybookCLI/Tools.swift`. It
becomes a CLI command (`stories render`) and an MCP tool (`stories-render`),
the same naming scheme as Storybook 11. The app runs the WebSocket server:
on the simulator it listens on `127.0.0.1:9300`; on a device it listens on
the LAN and requires the token shown in the app's Connect sheet (pass the
sheet's URL with `--url`).

To register the MCP server with Claude Code:

```bash
claude mcp add ios-storybook -- /path/to/ios-storybook/.build/debug/storybook mcp
```

## Layout

| Target | Platform | Role |
| --- | --- | --- |
| `StorybookProtocol` | any | Wire types: `JSONValue`, `index.json` v5, argTypes, RPC messages |
| `Storybook` | any | Story format: `Stories`, `StoryMeta`, `Story`, args, decorators, Storybook-exact ids |
| `StorybookRuntime` | iOS (scanner and store build on macOS) | Discovery, store, renderer and capture, agent server, launch args |
| `StorybookUI` | iOS | Browser: full-screen canvas, bottom bar, stories sheet, live addons sheet (Controls, Actions), globals, Connect sheet |
| `storybook` | macOS | CLI and stdio MCP server |

`swift test` runs the format, discovery and store tests on macOS. The id
tests use Storybook's own test vectors.

## Experiments

[`experiments/open-services/`](experiments/open-services/README.md) plugs
this native runtime into Storybook 11's Node dev server through Open Services,
with no changes to Storybook:

- **Web**: iOS stories in the web Storybook UI, with Controls, Actions and
  toolbar globals rendering natively on the device.
- **Headless** ([`HEADLESS.md`](experiments/open-services/HEADLESS.md)): no
  browser at all. A framework-neutral `storybook-remote-renderer` package
  lets `storybook tools`, the tools SDK and MCP drive the iOS app; the
  iOS-specific part is about 65 lines.

Both write-ups end with what Storybook 11 is still missing for native
frameworks.
