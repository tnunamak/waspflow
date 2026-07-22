import { defineConfig } from 'vite';
import { resolve } from 'node:path';

export default defineConfig({
  esbuild: { jsx: 'automatic', jsxImportSource: 'preact' },
  build: {
    outDir: resolve(import.meta.dirname, '../public'),
    emptyOutDir: false,
    cssCodeSplit: false,
    lib: { entry: resolve(import.meta.dirname, 'src/main.jsx'), formats: ['es'], fileName: () => 'app.mjs', cssFileName: 'app' },
    rollupOptions: { output: { assetFileNames: '[name][extname]' } },
  },
});
