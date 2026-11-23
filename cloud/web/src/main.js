import { createApp } from 'vue'
import ElementPlus from 'element-plus'
import zhCn from 'element-plus/es/locale/lang/zh-cn.mjs'
import 'element-plus/dist/index.css'
import App from './App.vue'
import ReportPage from './ReportPage.vue'
import AuthCallback from './AuthCallback.vue'

const reportRoute = location.pathname.match(/^\/(r|share)\/([^/]+)\/?$/)
const view = location.pathname === '/auth/callback' ? AuthCallback : reportRoute ? ReportPage : App
const props = reportRoute ? { kind: reportRoute[1], identifier: decodeURIComponent(reportRoute[2]) } : {}
createApp(view, props).use(ElementPlus, { locale: zhCn }).mount('#app')
