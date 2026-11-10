// Headless: no web manager, no preview iframe. Run with
//   storybook dev -c .storybook-headless --preview-only
export default {
  framework: {
    name: 'storybook-ios-headless',
    options: {
      simulator: process.env.STORYBOOK_IOS_SIMULATOR ?? 'booted',
      bundleId: 'dev.storybook.openservices',
    },
  },
  stories: ['../../../Examples/SampleDesignSystem/Sources/**/*+Stories.swift'],
};
