// Drives the headless Storybook from Node with the public tools SDK: renders
// every story in light and dark on the connected peer.
//   node scripts/render-all.mjs [outDir]
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';

import { createTools } from 'storybook/internal/tools';

const outDir = process.argv[2] ?? 'renders';
await mkdir(outDir, { recursive: true });

const tools = await createTools({ cwd: process.cwd(), configDir: '.storybook-headless', port: 6007, mode: 'attached' });
const call = async (method, input) => {
  const outcome = await tools.call(method, input);
  if (!outcome.ok) throw new Error(`${method}: ${outcome.markdown}`);
  return outcome.data;
};

try {
  const { peers } = await call('device.list', {});
  if (peers.length === 0) throw new Error('No peer connected.');
  const index = await (await fetch(`${tools.storybook.url}/index.json`)).json();
  const ids = Object.keys(index.entries);
  console.log(`${tools.mode} to ${tools.storybook.url}; peer ${peers[0].name}; ${ids.length} stories`);

  const started = performance.now();
  let deviceMs = 0;
  for (const colorScheme of ['light', 'dark']) {
    await call('device.setGlobals', { globals: { colorScheme } });
    for (const storyId of ids) {
      const data = await call('device.render', { storyId, outPath: join(outDir, `${storyId}.${colorScheme}.png`) });
      deviceMs += data.renderMs;
    }
  }
  const total = performance.now() - started;
  const count = ids.length * 2;
  console.log(`${count} renders in ${Math.round(total)} ms (${Math.round(total / count)} ms each, ${Math.round(deviceMs / count)} ms of it on the device)`);
  await call('device.setGlobals', { globals: { colorScheme: 'light' } });
} finally {
  await tools.close();
}
