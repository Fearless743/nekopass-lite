import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'

const documents = ['home','login','profile','forward_rules','admin','admin_announcements','admin_users','admin_user_rules','admin_nodes','admin_node_protocols','admin_node_groups','admin_settings']
export default defineConfig({
  appType: 'mpa',
  plugins: [vue()],
  build: { rollupOptions: { input: Object.fromEntries(documents.map(name => [name,fileURLToPath(new URL(`./pages/${name}.html`, import.meta.url))])) } },
})
