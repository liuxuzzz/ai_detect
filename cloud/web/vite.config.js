import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Local development uses the same relative /api URLs as the production bundle.
export default defineConfig({
  plugins: [vue()],
  server: { proxy: { '/api': 'http://127.0.0.1:6600', '/health': 'http://127.0.0.1:6600' } },
})
