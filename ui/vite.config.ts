import { defineConfig } from 'vite';
export default defineConfig({
  root: '.',                   // run vite FROM ui/
  server: {
    host: '127.0.0.1',
    port: 5173,
    proxy: {
      // keep /api prefix; forward to Worker dev on 8787
      '/api': { target: 'http://127.0.0.1:8787', changeOrigin: true, secure: false }
    }
  }
});
