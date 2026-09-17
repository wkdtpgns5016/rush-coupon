import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig, loadEnv } from 'vite'

// https://vite.dev/config/
export default defineConfig(({ mode, command }) => {
  if (command === 'build') {
    const env = loadEnv(mode, process.cwd(), 'VITE_')
    if (!env.VITE_API_BASE_URL) {
      throw new Error(
        'VITE_API_BASE_URL이 설정되지 않았습니다. 프로덕션 빌드는 localhost로 조용히 폴백하지 않고 여기서 실패합니다.',
      )
    }
  }

  return {
    plugins: [react(), tailwindcss()],
  }
})
