// Server-side half of the framework: registers the ios/* services and the
// `ios` toolset from the `services` preset hook.
import { mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

import * as v from 'valibot';
import { defineToolset, registerToolset } from 'storybook/open-service';
import { experimental_registerService as registerService } from 'storybook/internal/core-server';

import { iosBridgeService, iosDeviceService } from './services.js';

const ACTION_EVENT = 'storybook/actions/action-event';
const STALE_AFTER_MS = 15_000;

/** Native story descriptions from the last device that connected. */
export const manifest = {
  stories: new Map(),
  listeners: new Set(),
  update(stories) {
    const before = JSON.stringify([...this.stories.values()]);
    this.stories = new Map(stories.map((story) => [story.entry.id, story]));
    if (JSON.stringify(stories) !== before) for (const listener of this.listeners) listener();
  },
};

let channel;
/** Set from `experimental_serverChannel`; absent inside an attached `storybook tools` process. */
export function setChannel(serverChannel) {
  channel = serverChannel;
}

let actionCount = 0;

export function registerIosServices({ manifestPath }) {
  const device = registerService(iosDeviceService);

  const bridge = registerService(iosBridgeService, {
    commands: {
      deviceConnected: {
        handler: async (input, ctx) => {
          const { stories = [], ...info } = input;
          ctx.self.setState((state) => {
            state.devices[input.deviceId] = { ...info, storyCount: stories.length, lastSeen: Date.now() };
          });
          manifest.update(stories);
          await mkdir(dirname(manifestPath), { recursive: true });
          await writeFile(manifestPath, JSON.stringify({ stories }, null, 2));
          return { ok: true };
        },
      },
      heartbeat: {
        handler: async ({ deviceId }, ctx) => {
          const now = Date.now();
          ctx.self.setState((state) => {
            if (state.devices[deviceId]) state.devices[deviceId].lastSeen = now;
            for (const [id, entry] of Object.entries(state.devices)) {
              if (now - entry.lastSeen > STALE_AFTER_MS) delete state.devices[id];
            }
          });
          return { ok: true };
        },
      },
      deviceEvent: {
        handler: async ({ deviceId, event, data }, ctx) => {
          if (event === 'storySelected') {
            ctx.self.setState((state) => {
              if (state.devices[deviceId]) state.devices[deviceId].selected = data.storyId;
            });
          }
          // Taps on the device show up in the web Actions panel.
          if (event === 'actionFired' && channel) {
            channel.emit(ACTION_EVENT, {
              id: `ios-${deviceId}-${data.id}-${++actionCount}`,
              count: 0,
              data: { name: data.name, args: [data.payload] },
              options: { limit: 50, clearOnStoryChange: true },
            });
          }
          return { ok: true };
        },
      },
      // The preview and attached CLIs can't reach the device directly:
      // command invokes are never relayed between clients. So they call
      // these hub handlers, and the hub's handler-less `ios/device` commands
      // broadcast to the devices.
      render: {
        handler: async (input) => {
          const result = await device.commands.render(input);
          return { ...pick(result, ['storyId', 'png', 'width', 'height', 'scale', 'renderMs']), deviceId: input.deviceId };
        },
      },
      listDevices: { handler: async (_input, ctx) => ctx.self.state.devices },
      call: {
        handler: async ({ command, input }) => {
          const fn = device.commands[command];
          if (!fn) throw new Error(`ios/device has no command '${command}'`);
          return fn(input);
        },
      },
    },
  });

  registerToolset(iosToolset);
  return { bridge, device };
}

function pick(object, keys) {
  return Object.fromEntries(keys.map((key) => [key, object[key]]));
}

const deviceId = v.optional(v.pipe(v.string(), v.description('Target device; defaults to every connected device (first answer wins).')));
const jsonObject = v.record(v.string(), v.any());

const bridgeOf = (ctx) => ctx.getService(iosBridgeService.id);

/** Agent-facing surface. Exposed by `storybook tools ios …` and `createTools`. */
export const iosToolset = defineToolset({
  id: 'ios',
  description: 'Render and drive native iOS stories on connected simulators and devices.',
  methods: {
    devices: {
      title: 'List connected iOS devices',
      description: 'Devices connected to this Storybook, with the story each one shows.',
      input: v.strictObject({}),
      requiresDevServer: true,
      handler: async (_input, ctx) => {
        // Not `queries.devices.get()`: in an attached `storybook tools` process
        // the handler runs before this replica's first sync (~250 ms), and
        // `loaded()` doesn't wait for sync. A hub command reads the source.
        const devices = await bridgeOf(ctx).commands.listDevices({});
        const list = Object.entries(devices ?? {}).map(([id, d]) => ({ id, ...d }));
        return {
          ok: true,
          data: { devices: list },
          markdown: list.length
            ? list.map((d) => `- **${d.name}** (${d.id}), ${d.osVersion}: ${d.storyCount} stories, showing \`${d.selected ?? 'nothing'}\``)
            : 'No iOS devices are connected. Launch the host app with `-StorybookServer <url>`.',
        };
      },
    },
    render: {
      title: 'Render an iOS story to PNG',
      description: 'Renders a story on the device with optional args and globals, writes a PNG and returns its path.',
      input: v.strictObject({
        storyId: v.string(),
        args: v.optional(jsonObject),
        globals: v.optional(jsonObject),
        bleed: v.optional(v.number()),
        deviceId,
        outPath: v.optional(v.pipe(v.string(), v.description('Where to write the PNG. Defaults to a temp file.'))),
      }),
      requiresDevServer: true,
      handler: async ({ outPath, ...input }, ctx) => {
        const result = await bridgeOf(ctx).commands.render(input);
        const path = outPath ?? join(tmpdir(), `storybook-ios-${input.storyId}-${Date.now()}.png`);
        await writeFile(path, Buffer.from(result.png, 'base64'));
        const data = { storyId: result.storyId, path, width: result.width, height: result.height, scale: result.scale, renderMs: result.renderMs };
        return { ok: true, data, markdown: `Rendered \`${data.storyId}\` (${data.width}×${data.height} pt @${data.scale}x, ${data.renderMs} ms): ${path}` };
      },
    },
    select: {
      title: 'Show a story on the device',
      description: 'Switches the device to a story.',
      input: v.strictObject({ storyId: v.string(), deviceId }),
      requiresDevServer: true,
      handler: async (input, ctx) => {
        const data = await bridgeOf(ctx).commands.call({ command: 'select', input });
        return { ok: true, data, markdown: `Showing \`${input.storyId}\`.` };
      },
    },
    setArgs: {
      title: 'Set story args on the device',
      description: 'Merge-patches args (null removes one) and returns the full args.',
      input: v.strictObject({ storyId: v.string(), args: jsonObject, deviceId }),
      requiresDevServer: true,
      handler: async (input, ctx) => {
        const data = await bridgeOf(ctx).commands.call({ command: 'setArgs', input });
        return { ok: true, data, markdown: '```json\n' + JSON.stringify(data.args, null, 2) + '\n```' };
      },
    },
    actions: {
      title: 'List actions fired on the device',
      description: 'Actions (button taps and other callbacks) recorded on the device.',
      input: v.strictObject({ storyId: v.optional(v.string()), deviceId }),
      requiresDevServer: true,
      handler: async (input, ctx) => {
        const data = await bridgeOf(ctx).commands.call({ command: 'listActions', input });
        const actions = data.actions ?? [];
        return {
          ok: true,
          data,
          markdown: actions.length ? actions.map((a) => `- ${a.name}(${a.payload}) on \`${a.storyId}\``) : 'No actions recorded.',
        };
      },
    },
  },
});
