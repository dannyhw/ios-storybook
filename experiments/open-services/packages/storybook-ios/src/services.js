// Open Services contracts for iOS devices, shared by every runtime: the
// server registers both, the preview and manager register `ios/bridge`, and
// the Swift app implements `ios/device` on the wire.
import * as v from 'valibot';

// `defineService` is a typed identity function. It is not one of the
// manager/preview runtime globals, so importing it here would bundle a second
// copy of `storybook/open-service` into the browser; plain objects avoid that.
const defineService = (definition) => definition;

const anyObject = v.record(v.string(), v.any());
const renderInput = v.object({
  storyId: v.string(),
  args: v.optional(anyObject),
  globals: v.optional(anyObject),
  bleed: v.optional(v.number()),
  deviceId: v.optional(v.string()),
});
const renderOutput = v.object({
  storyId: v.string(),
  png: v.string(),
  width: v.number(),
  height: v.number(),
  scale: v.number(),
  renderMs: v.number(),
  deviceId: v.optional(v.string()),
});

/**
 * Implemented by the Swift app (`OpenServicesPeer`). The server registers it
 * with no handlers, so every call is broadcast to connected devices; inputs
 * carry an optional `deviceId` because Open Services has no routing.
 */
export const iosDeviceService = defineService({
  id: 'ios/device',
  description: 'Commands a connected iOS device runs. Implemented natively by the Swift app.',
  initialState: {},
  queries: {},
  commands: {
    describe: { description: 'Device info plus every story with argTypes.', input: v.object({ deviceId: v.optional(v.string()) }), output: v.any() },
    render: { description: 'Render a story and return a PNG.', input: renderInput, output: v.any() },
    select: { description: 'Show a story on the device.', input: v.object({ storyId: v.string(), deviceId: v.optional(v.string()) }), output: v.any() },
    setArgs: { description: 'Merge-patch the args of a story.', input: v.object({ storyId: v.string(), args: anyObject, deviceId: v.optional(v.string()) }), output: v.any() },
    setGlobals: { description: 'Merge-patch the device globals.', input: v.object({ globals: anyObject, deviceId: v.optional(v.string()) }), output: v.any() },
    listActions: { description: 'Actions fired on the device.', input: v.object({ storyId: v.optional(v.string()), deviceId: v.optional(v.string()) }), output: v.any() },
  },
});

/**
 * Hub-side state and commands. Handlers run on the dev server; every other
 * runtime (preview, manager, an attached `storybook tools`, the Swift app)
 * calls them remotely and sees `devices` through state sync.
 */
export const iosBridgeService = defineService({
  id: 'ios/bridge',
  description: 'Connected iOS devices and a relay to them.',
  initialState: { devices: {} },
  queries: {
    devices: {
      description: 'Connected devices, keyed by id.',
      input: v.void(),
      output: v.any(),
      handler: (_input, ctx) => ctx.self.state.devices,
    },
  },
  commands: {
    deviceConnected: { description: 'Called by a device when it joins.', input: v.looseObject({ deviceId: v.string() }), output: v.any() },
    heartbeat: { description: 'Called by a device every few seconds.', input: v.object({ deviceId: v.string() }), output: v.any() },
    deviceEvent: { description: 'Store events from a device: actions, args, selection.', input: v.object({ deviceId: v.string(), event: v.string(), data: v.any() }), output: v.any() },
    listDevices: { description: 'Connected devices, read on the hub (replicas may not have synced yet).', input: v.object({}), output: v.any() },
    render: { description: 'Render a story on a device and return a PNG.', input: renderInput, output: renderOutput },
    call: {
      description: 'Run any ios/device command through the hub.',
      input: v.object({ command: v.string(), input: anyObject }),
      output: v.any(),
    },
  },
});
