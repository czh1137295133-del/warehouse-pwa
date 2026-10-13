import {defineConfig} from 'vite';import {VitePWA} from 'vite-plugin-pwa';
export default defineConfig({plugins:[VitePWA({registerType:'autoUpdate',manifest:{name:'仓库管家',short_name:'仓库',start_url:'/',display:'standalone',background_color:'#f5f7f6',theme_color:'#145c4c',icons:[{src:'/icon.svg',sizes:'any',type:'image/svg+xml',purpose:'any'}]},workbox:{navigateFallback:'/index.html'}})]});
