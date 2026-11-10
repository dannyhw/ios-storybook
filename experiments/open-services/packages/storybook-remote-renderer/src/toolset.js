// The agent surface, framework-neutral: `storybook tools device …`, the SDK,
// and (through ./mcp.js) MCP. Every method goes through hub commands.
import { writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import * as v from 'valibot';
import { defineToolset } from 'storybook/open-service';

import { hubService } from './contract.js';

const json = v.record(v.string(), v.any());
const peerId = v.optional(v.pipe(v.string(), v.description('Target peer. Defaults to every connected peer (first answer wins).')));

const hub = (ctx) => ctx.getService(hubService.id);
const call = (ctx, command, input) => hub(ctx).commands.call({ command, input });
const ok = (data, markdown) => ({ ok: true, data, markdown });

export const deviceToolset = defineToolset({
  id: 'device',
  description: 'Render and drive stories on connected renderer peers (simulators, devices, native apps).',
  methods: {
    list: {
      title: 'List connected peers',
      description: 'Peers connected to this Storybook and the story each one shows.',
      input: v.strictObject({}),
      requiresDevServer: true,
      handler: async (_input, ctx) => {
        const { peers } = await hub(ctx).commands.snapshot({});
        const list = Object.entries(peers).map(([id, peer]) => ({ id, ...peer, args: undefined }));
        return ok(
          { peers: list },
          list.length
            ? list.map((p) => `- **${p.name}** \`${p.id}\` (${p.platform} ${p.osVersion}): ${p.storyCount} stories, showing \`${p.selected ?? 'nothing'}\``)
            : 'No renderer peers are connected.'
        );
      },
    },
    story: {
      title: 'Describe a story',
      description: 'argTypes, initial args and current args of a story, as reported by the peer. No browser preview needed.',
      input: v.strictObject({ storyId: v.string() }),
      requiresDevServer: true,
      handler: async ({ storyId }, ctx) => {
        const { stories, peers } = await hub(ctx).commands.snapshot({});
        const story = stories[storyId];
        if (!story) return { ok: false, data: { storyId }, markdown: `No metadata for \`${storyId}\`. Is a peer connected?` };
        const current = Object.values(peers).find((p) => p.args?.[storyId])?.args[storyId];
        const rows = story.argOrder.map((key) => {
          const t = story.argTypes[key];
          const control = t.control?.type ?? (t.action ? 'action' : '');
          const value = JSON.stringify((current ?? story.initialArgs)[key]);
          return `| \`${key}\` | ${t.type?.name ?? ''} | ${control}${t.options ? ` (${t.options.join(', ')})` : ''} | ${value ?? ''} |`;
        });
        return ok(
          { storyId, ...story, args: current ?? story.initialArgs },
          [`# ${story.title} / ${story.name}`, '| Arg | Type | Control | Value |\n| --- | --- | --- | --- |\n' + rows.join('\n')]
        );
      },
    },
    render: {
      title: 'Render a story to PNG',
      description: 'Renders a story on the peer with optional args and globals and returns the image.',
      input: v.strictObject({
        storyId: v.string(),
        args: v.optional(json),
        globals: v.optional(json),
        bleed: v.optional(v.number()),
        peerId,
        outPath: v.optional(v.pipe(v.string(), v.description('Where to write the PNG. Defaults to a temp file.'))),
      }),
      requiresDevServer: true,
      handler: async ({ outPath, ...input }, ctx) => {
        const result = await call(ctx, 'render', input);
        const path = outPath ?? join(tmpdir(), `storybook-${input.storyId}-${Date.now()}.png`);
        await writeFile(path, Buffer.from(result.png, 'base64'));
        const data = { storyId: result.storyId, path, width: result.width, height: result.height, scale: result.scale, renderMs: result.renderMs };
        // MCP turns `image` into an image content block (see ./mcp.js).
        if (ctx.transport === 'mcp') data.image = { mimeType: 'image/png', data: result.png };
        return ok(data, `Rendered \`${data.storyId}\` (${data.width}×${data.height} pt @${data.scale}x, ${data.renderMs} ms): ${path}`);
      },
    },
    select: {
      title: 'Show a story on the peer',
      description: 'Switches the peer to a story.',
      input: v.strictObject({ storyId: v.string(), peerId }),
      requiresDevServer: true,
      handler: async (input, ctx) => ok(await call(ctx, 'select', input), `Showing \`${input.storyId}\`.`),
    },
    setArgs: {
      title: 'Set story args',
      description: 'Merge-patches args (null removes one) and returns the full args.',
      input: v.strictObject({ storyId: v.string(), args: json, peerId }),
      requiresDevServer: true,
      handler: async (input, ctx) => {
        const data = await call(ctx, 'setArgs', input);
        return ok(data, '```json\n' + JSON.stringify(data.args, null, 2) + '\n```');
      },
    },
    resetArgs: {
      title: 'Reset story args',
      description: 'Restores the story’s initial args.',
      input: v.strictObject({ storyId: v.string(), peerId }),
      requiresDevServer: true,
      handler: async (input, ctx) => {
        const data = await call(ctx, 'resetArgs', input);
        return ok(data, '```json\n' + JSON.stringify(data.args, null, 2) + '\n```');
      },
    },
    setGlobals: {
      title: 'Set globals',
      description: 'Merge-patches globals such as appearance, text size, locale or layout direction.',
      input: v.strictObject({ globals: json, peerId }),
      requiresDevServer: true,
      handler: async (input, ctx) => {
        const data = await call(ctx, 'setGlobals', input);
        return ok(data, '```json\n' + JSON.stringify(data, null, 2) + '\n```');
      },
    },
    actions: {
      title: 'List actions',
      description: 'Callbacks (taps etc.) fired on peers, newest last, from hub state.',
      input: v.strictObject({ storyId: v.optional(v.string()) }),
      requiresDevServer: true,
      handler: async ({ storyId }, ctx) => {
        const { actions } = await hub(ctx).commands.snapshot({});
        const list = actions.filter((a) => !storyId || a.storyId === storyId);
        return ok({ actions: list }, list.length ? list.map((a) => `- ${a.name}(${a.payload}) on \`${a.storyId}\``) : 'No actions recorded.');
      },
    },
  },
});
