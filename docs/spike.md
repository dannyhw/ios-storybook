# Spike 1: results

This is the first end-to-end slice suggested in
[`research/README.md`](research/README.md). It was built and checked on
2026-10-17 with Xcode 27.0 (27A266a), Swift 6.4 and an iPhone 17 simulator
running iOS 27.

## What it covers

- **Story format** (`Storybook`): `Stories`, `StoryMeta`, `Story.extend`,
  `Codable` args, `@Arg` overrides, `StoryColor`, `StoryAction`, decorators,
  layouts, UIKit stories. There is no macro yet, so `all` is written by hand.
- **Discovery** (`StorybookRuntime`): a `__swift5_proto` scan for `Stories`
  conformances, plus `StoryRegistry.register` as a fallback.
- **Renderer:** a `UIHostingController` per canvas. It sizes stories as
  centered, padded or fullscreen, applies globals (appearance, Dynamic Type,
  RTL, locale) as trait overrides, remounts on story switch, waits until the
  story's frame is stable across display frames, and crops captures with
  `drawHierarchy`, keeping a 16 pt margin so shadows survive.
- **Agent server:** a `NWListener` WebSocket. It listens on loopback on the
  simulator; on a device it listens on the LAN and requires a token. It
  serves 12 toolset methods.
- **UI** (`StorybookUI`), laid out like React Native Storybook: the story
  fills the screen, and a floating bottom bar shows the current story, a
  globals menu and an addons button. The story tree (with search) opens as a
  half-height sheet that scrolls in place. The addons sheet (Controls,
  Actions) leaves the canvas live, so you can tap the story while it's open;
  dragging it down parks it at a small detent, and it closes only from its
  close button. The canvas re-centres the story in the space above the
  sheet. The Connect sheet (QR code) is in the stories sheet.
- **CLI and MCP** (`storybook`): one tool table, exposed both as CLI commands
  and as a stdio MCP server.
- **Example:** `SampleDesignSystem` has four components (three SwiftUI, one
  UIKit) and 13 stories. `StorybookHost` is an XcodeGen sidecar app with a
  single line, `StorybookScene()`.

## Assumptions tested

| Assumption | Result |
| --- | --- |
| Our ids match Storybook's exactly | ✅ All of Storybook's `toId`, `storyNameFromExport`, `toStartCaseStr` and `combineTags` test vectors pass (`swift test`). |
| Conformance scanning finds `Stories` types without registration | ✅ On macOS (test binary) and in the simulator app. |
| The linker keeps stories in a module the host never imports | ✅ The host doesn't `import SampleDesignSystem`, and all 13 stories were found. |
| Controls can be inferred from `Codable` args through `Mirror` | ✅ text, boolean, number, range, select (from `CaseIterable` enums), color, action, optional, hidden. |
| Args work as JSON across the wire | ✅ `args set` re-renders with no rebuild. Unknown arg names and wrong types return clear errors. |
| UI and agent share one state (tier 0) | ✅ CLI edits appear in the Controls panel; a toggle in the app shows up in `args get`; taps appear in `actions list`. |
| Rebuild, relaunch and restore (tier 1) | ✅ `-StorybookStory/-StorybookArgs/-StorybookGlobals` restore selection, args and globals. |
| "Render story X with args Y, return a PNG" | ✅ About 150–200 ms per render, cropped to the component, @3x. |
| MCP over stdio | ✅ `initialize`, `tools/list` (12 tools), `tools/call` returning image content, errors returned as `isError` results. |

Screenshots from the run are in [`spike/`](spike/), for example
[`pay-custom-dark.png`](spike/pay-custom-dark.png),
[`badge2.png`](spike/badge2.png) (UIKit), [`card.png`](spike/card.png)
(padded, with its shadow), [`ui-stories.png`](spike/ui-stories.png) and
[`ui-addons.png`](spike/ui-addons.png).

## Problems found and fixed

- **Optional `@Arg` values couldn't be cleared.** A JSON merge patch deletes
  keys set to `null`, but a property wrapper needs its key to be present to
  decode. Top-level args now keep an explicit `null`.
- **Launch arguments with JSON values were ignored.** `UserDefaults` parses
  `-Key {…}` as an old-style plist dictionary. The session now reads raw
  `ProcessInfo.arguments`.
- **UIKit stories stretched to the full width.** Sizing now uses the
  compressed size first, and wraps to the proposed width only when the
  component doesn't fit.
- **Dark mode didn't apply.** SwiftUI owns the trait overrides of a
  `UIViewControllerRepresentable`'s controller, so the style is now set on
  the inner hosting controller, and the canvas and capture backgrounds are
  resolved to match.

- **Shadows were cropped.** Captures now include a margin around the
  story's frame (`--bleed`, default 16 pt; `0` crops exactly), clamped to the
  canvas.
- **Settling used fixed delays.** It now lays out on each display frame
  until the story's frame is unchanged for two frames (30-frame cap), which
  also made repeat renders faster (about 80 ms).

## Known limitations and next steps

- **No static index or macro yet.** Next steps are a `@Stories` macro (which
  generates `all`, enforces literals and emits `@section` records) and a
  SwiftSyntax `storybook index`.
- **No "story ready" signal.** Settling waits for a stable layout, not for
  async loaders (images, data); stories that load should be able to signal
  readiness.
- **The capture needs the canvas on screen.** The new UI keeps it on screen
  at all times, but an offscreen render window would allow renders at other
  device sizes.
- **Requests use invoke → result, with no ack step**, and there's no delegated
  attach-or-launch mode. Today the CLI only attaches and prints a launch hint
  if nothing is running.
- **Not built yet:** play functions, a11y audits, a `#Preview` importer, the
  docs toolset, snapshot testing (`StorybookTesting`), `storybook init`, and
  testing on a physical device.
