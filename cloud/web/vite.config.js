import { defineConfig, loadEnv } from 'vite'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'

export default defineConfig(({ command, mode }) => {
  // Development shares cloud/.env. Production gets its address at container startup.
  const env = command === 'serve' ? loadEnv(mode, fileURLToPath(new URL('..', import.meta.url)), '') : {}
  return {
    plugins: [vue()],
    define: command === 'serve' ? {
      'import.meta.env.VITE_API_BASE_URL': JSON.stringify(env.WEB_API_BASE_URL || 'http://127.0.0.1:6601'),
    } : {},
  }
})
