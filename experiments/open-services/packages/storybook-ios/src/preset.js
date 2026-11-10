// The framework preset: everything a native iOS framework plugs into
// Storybook 11 through public(ish) preset hooks, with no core patches.
import { execFile } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { manifest, registerIosServices, setChannel } from './server.js';
import { readSwiftStories } from './swift-stories.js';

const here = dirname(fileURLToPath(import.meta.url));
const STORIES_FILE = /\+Stories\.swift$/;
const manifestPath = resolve('node_modules/.cache/storybook-ios/manifest.json');

// Contract 1: builder and renderer. The framework is its own renderer; its
// preview entry is a proxy that asks a device to render. `core.renderer` is
// left unset on purpose: naming this package there loads its preset twice.
export const core = {
  builder: fileURLToPath(import.meta.resolve('@storybook/builder-vite')),
};

export const previewAnnotations = (entries = []) => [...entries, join(here, 'entry-preview.js')];

export const managerEntries = (entries = []) => [...entries, join(here, 'manager.js')];

// Contract 2: story discovery. Swift files are indexed statically, so the
// sidebar works before any device connects.
const swiftIndexer = {
  test: STORIES_FILE,
  createIndex: async (fileName, { makeTitle }) => {
    const parsed = readSwiftStories(await readFile(fileName, 'utf8'), fileName);
    if (!parsed) return [];
    return parsed.stories.map((story) => ({
      type: 'story',
      importPath: fileName,
      exportName: story.exportName,
      name: story.name,
      title: makeTitle(parsed.title),
      tags: parsed.tags,
      // `Card+Stories.swift` documents `Card.swift`, which docs tools key on.
      rawComponentPath: fileName.replace(STORIES_FILE, '.swift'),
    }));
  },
};

// Contract 2b: component docs, through core's docgen worker.
// Dev only: in `storybook build`, docgenServer also requires an
// `experimental_manifests` component manifest, which this experiment skips.
export const isDocgenProviderEnabled = (_value, options) => options.configType === 'DEVELOPMENT';
export const experimental_docgenProvider = (existing = []) => [
  ...existing,
  { moduleSpecifier: join(here, 'docgen.js'), options: { manifestPath } },
];

// Story snippets for docs tools: the meta's render closure plus the story's
// own declaration, straight from the Swift source.
export const experimental_storyDocsProvider = async (next) => async (input) => {
  const { entry } = input;
  if (!entry.importPath?.endsWith('+Stories.swift')) return next(input);
  const source = await readFile(resolve(entry.importPath), 'utf8');
  const parsed = readSwiftStories(source, entry.importPath);
  const metaBlock = /static\s+let\s+meta\s*=[\s\S]*?\n    \}\n/.exec(source)?.[0]?.trim();
  const stories = {};
  for (const story of parsed?.stories ?? []) {
    const id = `${entry.id.split('--')[0]}--${story.exportName.replace(/([a-z0-9])([A-Z])/g, '$1-$2').toLowerCase()}`;
    const line = new RegExp(`static\\s+let\\s+${story.exportName}\\s*=.*`).exec(source)?.[0];
    stories[id] = { id, name: story.name ?? story.exportName, snippet: [metaBlock, line].filter(Boolean).join('\n\n') };
  }
  return { id: entry.id.split('--')[0], name: parsed?.title ?? entry.title, path: entry.importPath, stories };
};

export const experimental_indexers = (existing = []) => [swiftIndexer, ...existing];

// Contract 3: the preview must import every importPath as a CSF module, so
// `.swift` files become CSF here. argTypes and initial args come from the
// native manifest (what the device reported); without one, stories still
// list and render, just without Controls.
if (existsSync(manifestPath)) {
  try {
    manifest.update(JSON.parse(readFileSync(manifestPath, 'utf8')).stories ?? []);
  } catch {}
}

function swiftToCsf(file, source) {
  const parsed = readSwiftStories(source, file);
  if (!parsed) return 'export default {};';
  const lines = [`export default ${JSON.stringify({ title: parsed.title, tags: parsed.tags, parameters: { ios: { file } } })};`];
  for (const { exportName, name } of parsed.stories) {
    const native = [...manifest.stories.values()].find(
      (story) => story.entry.title === parsed.title && story.entry.exportName === exportName
    );
    const story = { parameters: { ios: { storyId: native?.entry.id } } };
    if (name) story.name = name;
    if (native) {
      story.argTypes = toArgTypes(native);
      story.args = Object.fromEntries(
        Object.entries(native.initialArgs ?? {}).filter(([key]) => !native.argTypes[key]?.action)
      );
    }
    // Swift names can be JS reserved words (`static let new`), so export by alias.
    const local = `story_${exportName}`;
    lines.push(`const ${local} = ${JSON.stringify(story)};`, `export { ${local} as ${exportName} };`);
  }
  return lines.join('\n');
}

/** Native argTypes already use Storybook's shapes; drop nulls and keep declaration order. */
function toArgTypes(native) {
  const result = {};
  for (const [index, key] of native.argOrder.entries()) {
    const { control, options, action, description, type, name } = native.argTypes[key];
    const argType = { name, type, table: { order: index } };
    if (description) argType.description = description;
    if (options) argType.options = options;
    if (action) argType.action = action;
    if (control) argType.control = Object.fromEntries(Object.entries(control).filter(([, value]) => value != null));
    else if (!action) argType.control = false;
    result[key] = argType;
  }
  return result;
}

export const viteFinal = async (config) => {
  config.plugins = [...(config.plugins ?? []), swiftCsfPlugin()];
  return config;
};

function swiftCsfPlugin() {
  let server;
  return {
    name: 'storybook-ios:swift-csf',
    enforce: 'pre',
    configureServer(viteServer) {
      server = viteServer;
      // When a device reports new argTypes, hot-reload the affected modules.
      manifest.listeners.add(() => {
        for (const mod of server.moduleGraph.idToModuleMap.values()) {
          if (mod.file && STORIES_FILE.test(mod.file)) server.reloadModule(mod);
        }
      });
    },
    async load(id) {
      const file = id.split('?')[0];
      if (!STORIES_FILE.test(file)) return;
      this.addWatchFile(file);
      return { code: swiftToCsf(file, await readFile(file, 'utf8')), map: null };
    },
  };
}

// Contract 4: services and toolsets. Runs in the dev server and in every
// attached `storybook tools` process, so it only registers.
export const services = async () => {
  registerIosServices({ manifestPath });
};

// Contract 5: device connection. The device joins the existing server
// channel with the instance token; this hook only captures the channel and
// tells the user (or a simulator) where to connect.
export const experimental_serverChannel = async (channel, options) => {
  setChannel(channel);
  const token = globalThis.STORYBOOK_WEBSOCKET_TOKEN;
  const url = `ws://127.0.0.1:${options.port}/storybook-server-channel?token=${token}`;
  const framework = await options.presets.apply('frameworkOptions');
  console.log(`[storybook-ios] devices connect to ${url}`);
  if (framework?.simulator && framework?.bundleId) {
    // Relaunch the host app pointed at this server, like a builder would.
    execFile('xcrun', ['simctl', 'terminate', framework.simulator, framework.bundleId], () => {
      execFile('xcrun', ['simctl', 'launch', framework.simulator, framework.bundleId, '-StorybookServer', url], (error) => {
        if (error) console.warn(`[storybook-ios] could not launch ${framework.bundleId}: ${error.message}`);
      });
    });
  }
  return channel;
};
