<script setup lang="ts">
import { copyText } from '../clipboard'
import { reactive,ref } from 'vue'
import { ElMessage,ElMessageBox } from 'element-plus'
import PageShell from '../PageShell.vue'
import {usePage} from '../page'
import {api} from '../api'
import {loadSite} from '../site'
type Settings={site_name:string;panel_url:string;agent_host:string;agent_port:number;agent_transport:string;installer_url:string;release_base_url:string;agent_version:string;install_token_minutes:number;proxy_trusted_cidrs:string[];target_deny_cidrs:string[]}
const form=reactive<Settings>({site_name:'Nekopass',panel_url:'',agent_host:'',agent_port:9443,agent_transport:'tls',installer_url:'https://github.com/fearless743/nekopass-lite/releases/latest/download/install-agent.sh',release_base_url:'https://github.com/fearless743/nekopass-lite/releases/download',agent_version:'latest',install_token_minutes:30,proxy_trusted_cidrs:[],target_deny_cidrs:[]})
const proxyTrustText=ref(''),targetDenyText=ref('')
const cidrs=(text:string)=>text.split(/[,\s]+/).filter(Boolean)
const activeTab=ref('site')
const listener=ref<{address:string;mode:string}|null>(null)
const hasKey=ref(false),customKey=ref(''),shownKey=ref(''),keyDialog=ref(false)
async function loadSettings(){const data=await api<{settings:Settings;api_key_configured:boolean;agent_listener:{address:string;mode:string}|null}>('admin/settings');Object.assign(form,data.settings);proxyTrustText.value=(form.proxy_trusted_cidrs||[]).join('\n');targetDenyText.value=(form.target_deny_cidrs||[]).join('\n');hasKey.value=data.api_key_configured;listener.value=data.agent_listener}
const {me,loading,error,busy,run}=usePage(async()=>{await loadSettings()},{admin:true})
function currentAddress(){form.panel_url=location.origin;form.agent_host=location.hostname.replace(/^\[|\]$/g,'')}
async function save(){await run(async()=>{await api('admin/settings','PUT',{...form,proxy_trusted_cidrs:cidrs(proxyTrustText.value),target_deny_cidrs:cidrs(targetDenyText.value)});await loadSettings();await loadSite();ElMessage.success('系统设置已保存')})}
async function key(){try{if(hasKey.value)await ElMessageBox.confirm('生成或设置新密钥会使旧管理 API 密钥失效。','更新管理密钥',{confirmButtonText:'更新',cancelButtonText:'取消'});await run(async()=>{const data=await api<{key:string}>('admin/settings/api-key','POST',{key:customKey.value});shownKey.value=data.key;customKey.value='';hasKey.value=true;keyDialog.value=true})}catch{/* cancelled */}}
async function revoke(){try{await ElMessageBox.confirm('撤销后，现有管理 API 密钥将不能调用后台接口。','撤销管理密钥',{confirmButtonText:'撤销',cancelButtonText:'取消'});await run(async()=>{await api('admin/settings/api-key','DELETE',{});hasKey.value=false;ElMessage.success('管理 API 密钥已撤销')})}catch{/* cancelled */}}
async function copyKey(){try{await copyText(shownKey.value);ElMessage.success('密钥已复制')}catch{ElMessage.warning('复制失败，请手动选择复制')}}
</script>

<template>
  <PageShell :me="me" :loading="loading" :error="error" active="settings" admin>
    <section class="surface">
      <div class="section-header">
        <strong>系统设置</strong>
        <el-button type="primary" :loading="busy" @click="save">保存设置</el-button>
      </div>
      <el-tabs v-model="activeTab" class="settings-tabs">
        <el-tab-pane label="站点与连接" name="site">
          <div class="section-body settings-form">
            <el-form label-position="top" @submit.prevent="save">
              <div class="form-section-title">站点与连接地址</div>
              <el-form-item label="站点名称"><el-input v-model="form.site_name" maxlength="64" /></el-form-item>
              <el-form-item label="面板对外地址"><el-input v-model="form.panel_url" placeholder="https://panel.example.com" /><el-button class="settings-inline-action" @click="currentAddress">填入当前面板地址</el-button></el-form-item>
              <div class="form-grid"><el-form-item label="Agent 主控域名 / IP"><el-input v-model="form.agent_host" placeholder="panel.example.com" /></el-form-item>
              <el-form-item label="Agent 控制端口"><el-input-number v-model="form.agent_port" :min="1" :max="65535" /></el-form-item>
              </div>
              <el-form-item label="节点连接方式"><el-select v-model="form.agent_transport"><el-option label="HTTPS（公共证书 / Nginx 代理）" value="tls"/><el-option label="HTTP（明文 HTTP/2）" value="plain"/></el-select><span class="field-tip">保存后立即切换主控连接方式，无需重启。HTTP 会关闭控制端口 TLS；HTTPS 使用已配置的证书，或已有 Nginx TLS 代理。</span></el-form-item>
              <p class="field-tip">填写节点能访问的外部地址和端口。在线的 v0.14.1 及以上节点会自动接收新地址；离线或旧版本节点需重新执行安装命令。HTTP 直连需放行主控控制端口。</p>
              <p v-if="listener" class="field-tip">当前控制监听：{{listener.address}} · {{listener.mode==='tls'?'TLS':listener.mode==='proxy'?'Nginx TLS 代理后端':'HTTP'}}</p>
            </el-form>
          </div>
        </el-tab-pane>
                        <el-tab-pane label="安全与 API" name="security">
          <div class="section-body settings-form">
            <el-form label-position="top" @submit.prevent="save">
              <div class="form-section-title">转发安全</div>
              <el-form-item label="PROXY Protocol 信任来源"><el-input v-model="proxyTrustText" type="textarea" :rows="4" placeholder="每行一个 CIDR，例如 192.0.2.10/32" /><span class="field-tip">只信任这些来源提供的客户端 IP；留空禁止规则接收 PROXY Protocol。仅管理员可以修改。</span></el-form-item>
              <el-form-item label="禁止转发的目标 IP 网段"><el-input v-model="targetDenyText" type="textarea" :rows="10" placeholder="每行一个 IPv4 / IPv6 CIDR" /><span class="field-tip">直转和隧道出口均检查实际解析后的 IP。默认禁止本机、内网、链路本地、组播、云 metadata 等特殊地址；需要内网转发时移除对应网段，留空允许全部目标。旧节点须升级后才能执行这些限制。</span></el-form-item>
            </el-form>
            <div class="form-section-title api-key-section">管理 API 密钥</div>
            <p class="subtle">{{hasKey?'已配置管理 API 密钥。原值不会再次显示。':'尚未配置管理 API 密钥。'}}此密钥用于自动化管理接口，不是节点密钥，也不会包含在节点安装命令中。</p>
            <el-input v-model="customKey" type="password" show-password autocomplete="new-password" placeholder="可填写 32–256 字符自定义密钥，留空自动生成" /><div class="admin-actions settings-key-actions"><el-button :loading="busy" @click="key">{{hasKey?'更新管理 API 密钥':'生成管理 API 密钥'}}</el-button><el-button v-if="hasKey" type="danger" plain :loading="busy" @click="revoke">撤销密钥</el-button></div>
          </div>
        </el-tab-pane>
        <el-tab-pane label="节点安装" name="installation">
          <div class="section-body settings-form">
            <el-form label-position="top" @submit.prevent="save">
              <div class="form-section-title">节点一键安装</div>
              <p class="field-tip">一键安装始终可用。默认从 GitHub Releases 下载，也可修改为自己的 HTTPS 下载源。</p>
              <el-form-item label="安装脚本地址"><el-input v-model="form.installer_url" placeholder="https://github.com/fearless743/nekopass-lite/releases/latest/download/install-agent.sh" /></el-form-item>
              <el-form-item label="Agent 版本下载根地址"><el-input v-model="form.release_base_url" placeholder="https://github.com/fearless743/nekopass-lite/releases/download" /></el-form-item>
              <div class="form-grid"><el-form-item label="Agent 版本"><el-input v-model="form.agent_version" placeholder="latest" /></el-form-item>
              </div>
            </el-form>
          </div>
        </el-tab-pane>
      </el-tabs>
      <div class="settings-footer">
        <span class="field-tip">保存所有栏目中的修改</span>
      </div>
    </section>
    <el-dialog v-model="keyDialog" title="保存管理 API 密钥" width="600px" @closed="shownKey=''" ><p>只显示这一次，请保存到自己的密钥管理工具中。</p>
    <el-input :model-value="shownKey" type="textarea" :rows="3" readonly /><template #footer><el-button type="primary" @click="copyKey">复制密钥</el-button></template></el-dialog>
  </PageShell>
</template>

<style scoped>
.settings-tabs :deep(.el-tabs__header) {
  margin: 0;
  padding: 12px 24px;
  border-bottom: 1px solid var(--border);
}
.settings-tabs :deep(.el-tabs__nav-wrap::after),
.settings-tabs :deep(.el-tabs__active-bar) { display: none; }
.settings-tabs :deep(.el-tabs__item) {
  height: 38px;
  padding: 0 16px !important;
  border-radius: 12px;
  font-weight: 500;
  transition: background-color .2s, color .2s;
}
.settings-tabs :deep(.el-tabs__item:hover),
.settings-tabs :deep(.el-tabs__item.is-active) {
  background: var(--el-color-primary-light-9);
  color: var(--el-color-primary);
}
.settings-tabs :deep(.el-tabs__nav-prev),
.settings-tabs :deep(.el-tabs__nav-next) { line-height: 38px; }
.settings-footer {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 18px 24px;
  border-top: 1px solid var(--border);
}
.settings-footer .field-tip { margin: 0; }
@media (max-width: 600px) {
  .settings-tabs :deep(.el-tabs__header) { padding: 10px 14px; }
  .settings-tabs :deep(.el-tabs__item) { padding: 0 13px !important; }
  .settings-form, .settings-footer { padding: 18px 16px; }
}
</style>
