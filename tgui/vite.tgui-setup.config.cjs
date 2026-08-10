const { createViteConfig } = require('./vite.base.config.cjs');

module.exports = createViteConfig({
  entry: 'packages/tgui-setup/index.js',
  bundleName: 'tgui-setup',
  globalName: 'TguiSetupBundle',
});
