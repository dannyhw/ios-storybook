// Docgen for Swift components, run by core's docgen worker. argTypes come
// from the native manifest; the description is the `///` comment above the
// component's type declaration.
import { readFile } from 'node:fs/promises';
import { basename } from 'node:path';

export function createDocgenProvider({ manifestPath }) {
  return (next) => async (input) => {
    const { entry } = input;
    if (!entry.importPath?.endsWith('+Stories.swift')) return next(input);
    const downstream = await next(input);
    const manifest = JSON.parse(await readFile(manifestPath, 'utf8').catch(() => '{"stories":[]}'));
    const native = manifest.stories.find((story) => story.entry.id === entry.id);
    const componentPath = entry.componentPath ?? entry.importPath.replace(/\+Stories\.swift$/, '.swift');
    const name = basename(componentPath, '.swift');
    const source = await readFile(componentPath, 'utf8').catch(() => '');
    const comment = new RegExp(`((?:^\\s*///.*\\n)+)\\s*(?:public\\s+|final\\s+)*(?:struct|class|enum)\\s+${name}\\b`, 'm').exec(source)?.[1];
    const description = comment?.split('\n').map((line) => line.replace(/^\s*\/\/\/ ?/, '')).join('\n').trim();
    return {
      ...downstream,
      id: downstream?.id ?? entry.id.split('--')[0],
      name: downstream?.name ?? name,
      path: downstream?.path ?? entry.importPath,
      description: downstream?.description ?? description,
      jsDocTags: downstream?.jsDocTags ?? {},
      argTypes: downstream?.argTypes ?? native?.argTypes,
      renderer: 'storybook-ios',
      apiDescription:
        downstream?.apiDescription ??
        (native
          ? `## Args\n\n| Name | Type | Control |\n| --- | --- | --- |\n` +
            native.argOrder.map((key) => `| \`${key}\` | ${native.argTypes[key].type?.name ?? ''} | ${native.argTypes[key].control?.type ?? (native.argTypes[key].action ? 'action' : '')} |`).join('\n')
          : undefined),
    };
  };
}
