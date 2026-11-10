// A static reader for `*+Stories.swift` files. It stands in for the planned
// SwiftSyntax `storybook index`: enough to list stories without compiling.

import { basename, dirname } from 'node:path';

/**
 * @param {string} source
 * @param {string} file used for the native auto-title (`Module/Component`)
 * @returns {{ title: string, tags: string[], stories: { exportName: string, name?: string }[] } | undefined}
 */
export function readSwiftStories(source, file) {
  // `StoryMeta(title: "A/B", …)`, `StoryMeta.uiView(title: …)` or no title.
  const meta = /StoryMeta(?:\.\w+)?\(([^\n]*)/.exec(source);
  if (!meta) return undefined;
  const title =
    /title:\s*"([^"]+)"/.exec(meta[1])?.[1] ??
    // Same rule as the Swift runtime: parent directory (module) / file stem.
    `${basename(dirname(file))}/${basename(file).replace(/\+Stories\.swift$/, '')}`;
  const tags = [...(/tags:\s*\[([^\]]*)\]/.exec(meta[1])?.[1] ?? '').matchAll(/"([^"]+)"/g)].map((m) => m[1]);

  // `static let disabled = primary.extend(name: "Disabled state") { … }`
  const names = new Map();
  for (const [, exportName, rest] of source.matchAll(/static\s+let\s+(\w+)\s*=\s*([^\n]*)/g)) {
    const name = /name:\s*"([^"]+)"/.exec(rest)?.[1];
    if (name) names.set(exportName, name);
  }

  // The `all` list fixes the order and the export names: `.init("primary", primary)`.
  const all = /static\s+var\s+all\b[\s\S]*?\[([\s\S]*?)\]\s*\}/.exec(source)?.[1] ?? '';
  const stories = [...all.matchAll(/\.init\(\s*"(\w+)"/g)].map(([, exportName]) => ({
    exportName,
    name: names.get(exportName),
  }));
  return { title, tags, stories };
}
