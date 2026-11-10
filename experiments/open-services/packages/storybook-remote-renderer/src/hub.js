// Server side of the contract: the hub service, registered from `services`.
import { experimental_registerService as registerService } from 'storybook/internal/core-server';

import { hubService, peerService } from './contract.js';

const ACTION_EVENT = 'storybook/actions/action-event';
const STALE_AFTER_MS = 15_000;
const MAX_ACTIONS = 50;

let channel;
/** Captured in `experimental_serverChannel`; absent in an attached `storybook tools` process. */
export const setChannel = (serverChannel) => {
  channel = serverChannel;
};

const connectedListeners = new Set();
/** Frameworks can react when a peer reports its stories (e.g. cache a manifest). */
export const onPeerConnected = (listener) => connectedListeners.add(listener);

export function registerHub() {
  const peer = registerService(peerService);

  const hub = registerService(hubService, {
    commands: {
      peerConnected: {
        handler: async (input, ctx) => {
          const { stories = [], peerId, ...info } = input;
          ctx.self.setState((state) => {
            state.peers[peerId] = { ...info, storyCount: stories.length, args: {}, lastSeen: Date.now() };
            for (const story of stories) {
              const { entry, argTypes, argOrder, initialArgs } = story;
              state.stories[entry.id] = { title: entry.title, name: entry.name, tags: entry.tags, argTypes, argOrder, initialArgs };
            }
          });
          for (const listener of connectedListeners) await listener(input);
          return { ok: true };
        },
      },
      heartbeat: {
        handler: async ({ peerId }, ctx) => {
          const now = Date.now();
          ctx.self.setState((state) => {
            if (state.peers[peerId]) state.peers[peerId].lastSeen = now;
            for (const [id, entry] of Object.entries(state.peers)) {
              if (now - entry.lastSeen > STALE_AFTER_MS) delete state.peers[id];
            }
          });
          return { ok: true };
        },
      },
      peerEvent: {
        handler: async ({ peerId, event, data }, ctx) => {
          ctx.self.setState((state) => {
            const entry = state.peers[peerId];
            if (!entry) return;
            if (event === 'storySelected') entry.selected = data.storyId;
            if (event === 'argsChanged') entry.args[data.storyId] = data.args;
            if (event === 'globalsChanged') entry.globals = data;
            if (event === 'actionFired') {
              // Arrays sync atomically, so replace rather than push.
              state.actions = [...state.actions, { ...data, peerId }].slice(-MAX_ACTIONS);
            }
          });
          // If a web manager happens to be open, its Actions panel shows these too.
          if (event === 'actionFired' && channel) {
            channel.emit(ACTION_EVENT, {
              id: `${peerId}-${data.id}`,
              count: 0,
              data: { name: data.name, args: [data.payload] },
              options: { limit: MAX_ACTIONS, clearOnStoryChange: true },
            });
          }
          return { ok: true };
        },
      },
      snapshot: { handler: async (_input, ctx) => ctx.self.state },
      call: {
        handler: async ({ command, input }) => {
          const fn = peer.commands[command];
          if (!fn) throw new Error(`${peerService.id} has no command '${command}'`);
          return fn(input);
        },
      },
    },
  });

  return { hub, peer };
}
