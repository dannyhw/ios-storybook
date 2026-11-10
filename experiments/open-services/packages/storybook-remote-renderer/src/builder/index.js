// A preview builder that builds nothing. Storybook's dev server refuses to
// start without `core.builder`, but a headless remote renderer has no preview
// to bundle: stories render on the peer.
//
// It lives in its own directory on purpose: `loadStorybook` (the
// `storybook tools` path) also loads any `preset.js` next to the builder
// module, which would apply this package's preset twice.
const noop = async () => {};

export const getConfig = async () => ({});
export const start = async ({ startTime }) => ({ totalTime: process.hrtime(startTime), bail: noop });
export const build = noop;
export const bail = noop;
