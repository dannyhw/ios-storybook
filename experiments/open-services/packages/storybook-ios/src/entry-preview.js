// The renderer: a proxy. The web preview has no Swift runtime, so it asks a
// connected device (through the `ios/bridge` service) to render the story and
// shows the PNG. Modelled on `@storybook/server`'s async renderToCanvas.
import { registerService } from 'storybook/preview-api';

import { iosBridgeService } from './services.js';

const bridge = registerService(iosBridgeService);

export const parameters = { renderer: 'storybook-ios', layout: 'centered' };

// Native globals become toolbar menus.
export const globalTypes = {
  colorScheme: { description: 'Appearance', toolbar: { title: 'Appearance', icon: 'mirror', items: ['light', 'dark'], dynamicTitle: true } },
  dynamicType: {
    description: 'Dynamic Type size',
    toolbar: { title: 'Text size', icon: 'paragraph', items: ['xSmall', 'large', 'xxxLarge', 'accessibility3'], dynamicTitle: true },
  },
  layoutDirection: { description: 'Layout direction', toolbar: { title: 'Direction', icon: 'transfer', items: ['leftToRight', 'rightToLeft'], dynamicTitle: true } },
};

/** CSF needs a render function; the real work happens in renderToCanvas. */
export const render = () => null;

let latest = 0;

export async function renderToCanvas({ storyContext, storyFn, showMain, showError }, canvas) {
  storyFn(); // runs decorators and args enhancers
  const { id, args, argTypes, globals } = storyContext;
  const ticket = ++latest;
  try {
    const result = await bridge.commands.render({
      storyId: id,
      args: nativeArgs(args, argTypes),
      globals: pick(globals, Object.keys(globalTypes)),
    });
    if (ticket !== latest) return; // a newer render (e.g. a slider drag) won
    const img = document.createElement('img');
    img.src = `data:image/png;base64,${result.png}`;
    img.width = result.width;
    img.height = result.height;
    img.alt = id;
    img.title = `${result.width}×${result.height} pt @${result.scale}x · ${result.renderMs} ms on device`;
    canvas.replaceChildren(img);
    showMain();
  } catch (error) {
    if (ticket !== latest) return;
    const noDevice = /Unhandled|no runtime|disconnected/i.test(error?.name + error?.message);
    showError({
      title: noDevice ? 'No iOS device connected' : 'The device could not render this story',
      description: noDevice
        ? 'Launch the host app with -StorybookServer <url> (printed by the dev server), or set framework.options.simulator.'
        : String(error?.message ?? error),
    });
  }
}

/** Action args become functions in the preview; the device owns its own. */
function nativeArgs(args, argTypes) {
  return Object.fromEntries(
    Object.entries(args).filter(([key, value]) => typeof value !== 'function' && !argTypes[key]?.action)
  );
}

function pick(object, keys) {
  return Object.fromEntries(keys.filter((key) => object[key] != null).map((key) => [key, object[key]]));
}
