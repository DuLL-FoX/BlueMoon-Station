const { createViteConfig } = require('./vite.base.config.cjs');

module.exports = createViteConfig({
  entry: 'packages/tgui-say/index.tsx',
  bundleName: 'tgui-say',
  globalName: 'TguiSayBundle',
});
