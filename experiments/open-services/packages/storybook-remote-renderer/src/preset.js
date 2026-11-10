// The headless remote-renderer preset. A framework preset re-exports this
// and adds `experimental_indexers` plus a way to start its peer.
import { fileURLToPath } from 'node:url';

import { registerToolset } from 'storybook/open-service';

import { registerHub, setChannel } from './hub.js';
import { mountMcp } from './mcp.js';
import { deviceToolset } from './toolset.js';

// No preview to bundle: stories render on the peer.
export const core = {
  builder: fileURLToPath(import.meta.resolve('./builder/index.js')),
  disableTelemetry: true,
};

// Runs in the dev server and in every attached `storybook tools` process.
export const services = async () => {
  registerHub();
  registerToolset(deviceToolset);
};

export const experimental_serverChannel = async (channel) => {
  setChannel(channel);
  return channel;
};

export const experimental_devServer = async (app, options) => {
  mountMcp(app, { path: '/mcp-all', origin: `http://127.0.0.1:${options.port}` });
  return app;
};

/** What a peer needs to join: the server channel URL with this instance's token. */
export const peerURL = (port) =>
  `ws://127.0.0.1:${port}/storybook-server-channel?token=${globalThis.STORYBOOK_WEBSOCKET_TOKEN}`;
