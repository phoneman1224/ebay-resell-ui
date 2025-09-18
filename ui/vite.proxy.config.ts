import { defineConfig } from 'vite';
export default defineConfig({
  root: '.',            // ui/ will be our CWD (see step 2)
  server: {
    host: '127.0.0.1',
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:8787',
        changeOrigin: true,
        secure: false
      }
    }
  }
});
