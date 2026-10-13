
import { defineConfig } from 'vite';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  base: '/warehouse-pwa/',
  plugins: [
    VitePWA({
      registerType: 'autoUpdate',
      manifest: {
        name: '仓库管家',
        short_name: '仓库',
        start_url: '/warehouse-pwa/',
        scope: '/warehouse-pwa/',
        display: 'standalone',
        background_color: '#f5f7f6',
        theme_color: '#145c4c',
        icons: [
          {
            src: '/warehouse-pwa/icon.svg',
            sizes: 'any',
            type: 'image/svg+xml',
            purpose: 'any'
          }
        ]
      },
      workbox: {
        navigateFallback: '/warehouse-pwa/index.html'
      }
    })
  ]
});
