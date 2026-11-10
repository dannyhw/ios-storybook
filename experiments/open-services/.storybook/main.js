/** @type {import('storybook-ios').StorybookConfig} */
export default {
  framework: {
    name: 'storybook-ios',
    options: {
      // Relaunch this app in this simulator pointed at the dev server.
      simulator: process.env.STORYBOOK_IOS_SIMULATOR ?? 'booted',
      bundleId: 'dev.storybook.openservices',
    },
  },
  stories: ['../../../Examples/SampleDesignSystem/Sources/**/*+Stories.swift'],
  addons: ['@storybook/addon-mcp'],
};
