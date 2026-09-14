import { defineConfig } from 'vite';
import solid from 'vite-plugin-solid';
import { viteSingleFile } from 'vite-plugin-singlefile';
export default defineConfig({
  publicDir: false,
  plugins: [solid(), viteSingleFile({ removeViteModuleLoader: true })],
  build: { outDir: 'dist', target: 'es2022', rolldownOptions: { checks: { pluginTimings: false } } },
});
