// Everything iOS-specific in the headless setup. The rest (builder, hub,
// toolset, MCP) comes from storybook-remote-renderer unchanged.
import { execFile } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { readSwiftStories } from 'storybook-ios/swift-stories';
import { onPeerConnected, peerURL } from 'storybook-remote-renderer';
import * as remote from 'storybook-remote-renderer/preset';

export const { core, services, experimental_devServer } = remote;

const STORIES_FILE = /\+Stories\.swift$/;
const manifestPath = resolve('node_modules/.cache/storybook-ios/manifest.json');

// 1. Discovery: list Swift stories without compiling.
export const experimental_indexers = (existing = []) => [
  {
    test: STORIES_FILE,
    createIndex: async (fileName, { makeTitle }) => {
      const parsed = readSwiftStories(await readFile(fileName, 'utf8'), fileName);
      return (parsed?.stories ?? []).map((story) => ({
        type: 'story',
        importPath: fileName,
        exportName: story.exportName,
        name: story.name,
        title: makeTitle(parsed.title),
        tags: parsed.tags,
        rawComponentPath: fileName.replace(STORIES_FILE, '.swift'),
      }));
    },
  },
  ...existing,
];

// 2. Docs: Swift doc comments and argTypes through core's docgen worker. The
// worker can't see hub state, so peers' story metadata is cached to a file.
onPeerConnected(async ({ stories }) => {
  await mkdir(dirname(manifestPath), { recursive: true });
  await writeFile(manifestPath, JSON.stringify({ stories }, null, 2));
});

export const isDocgenProviderEnabled = (_value, options) => options.configType === 'DEVELOPMENT';
export const experimental_docgenProvider = (existing = []) => [
  ...existing,
  { moduleSpecifier: fileURLToPath(import.meta.resolve('storybook-ios/docgen')), options: { manifestPath } },
];

// 3. Peer: (re)launch the host app on a simulator, pointed at this server.
export const experimental_serverChannel = async (channel, options) => {
  await remote.experimental_serverChannel(channel, options);
  const url = peerURL(options.port);
  const framework = await options.presets.apply('frameworkOptions');
  console.log(`[storybook-ios] peers connect to ${url}`);
  const { simulator, bundleId } = framework ?? {};
  if (simulator && bundleId) {
    execFile('xcrun', ['simctl', 'terminate', simulator, bundleId], () => {
      execFile('xcrun', ['simctl', 'launch', simulator, bundleId, '-StorybookServer', url, '-StorybookContract', 'remote-renderer'], (error) => {
        if (error) console.warn(`[storybook-ios] could not launch ${bundleId}: ${error.message}`);
      });
    });
  }
  return channel;
};
