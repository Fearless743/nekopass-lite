<script setup lang="ts">
import {computed,reactive,ref,watch} from 'vue'
import {ElMessage} from 'element-plus'
import Icon from './Icon.vue'
import EgressSelect from './EgressSelect.vue'
import {egressChoices,egressValue,splitEgress} from './egress-options'
import type {RuleEgressGroup} from './api'
import type {Rule,RuleNode,RuleBatchPatch} from './api'

type EntryRow={node_id:number;egress:string}
const props=defineProps<{modelValue:boolean;rules:Rule[];nodes:RuleNode[];egressGroups?:RuleEgressGroup[];busy:boolean;limitsLabel:string}>()
const emit=defineEmits<{
 'update:modelValue':[value:boolean]
 save:[value:{ids:number[];patch:RuleBatchPatch}]
 toggle:[value:{ids:number[];enabled:boolean}]
}>()
const form=reactive<RuleBatchPatch>({})
const advanced=ref<string[]>([])
const entryRows=ref<EntryRow[]>([])
let initialEntries=''
function clearField(key:keyof RuleBatchPatch){delete form[key]}
function entriesOf(r:Rule){return r.entries?.length?r.entries.map(e=>({node_id:e.node_id,egress_node_id:e.egress_node_id||0,egress_group_id:e.egress_group_id||0})):[{node_id:r.node_id,egress_node_id:r.egress_node_id||0,egress_group_id:r.egress_group_id||0}]}
const ruleNodeIDs=(r:Rule)=>entriesOf(r).map(e=>e.node_id)
function rowKey(rows:EntryRow[]){return JSON.stringify(rows.filter(r=>r.node_id).map(r=>({node_id:r.node_id,...splitEgress(r.egress)})).sort((a,b)=>a.node_id-b.node_id||a.egress_group_id-b.egress_group_id||a.egress_node_id-b.egress_node_id))}
function resetEntries(){
 const sets=props.rules.map(r=>rowKey(entriesOf(r).map(e=>({node_id:e.node_id,egress:egressValue(e.egress_node_id,e.egress_group_id)}))))
 entryRows.value=sets.length&&sets.every(v=>v===sets[0])
  ?entriesOf(props.rules[0]).map(e=>({node_id:e.node_id,egress:egressValue(e.egress_node_id,e.egress_group_id)}))
  :[{node_id:0,egress:'node:0'}]
 initialEntries=rowKey(entryRows.value)
}
watch(()=>props.modelValue,open=>{if(open){for(const key of Object.keys(form) as (keyof RuleBatchPatch)[])delete form[key];advanced.value=[];resetEntries()}})
const hasSharedTLS=computed(()=>props.rules.some(r=>!!r.tls_inbound_id))
const hasUDP=computed(()=>props.rules.some(r=>r.protocol==='udp'))
const ingressNodes=computed(()=>props.nodes.filter(n=>n.ingress_enabled))
function udpIngressAllowed(node:RuleNode){return !node.deny_udp_ingress_creation||props.rules.every(r=>r.protocol!=='udp'||ruleNodeIDs(r).includes(node.id))}
function rowIngressAllowed(id:number){const node=ingressNodes.value.find(n=>n.id===id);return !node||udpIngressAllowed(node)}
const ingressIDs=computed(()=>[...new Set(props.rules.flatMap(r=>ruleNodeIDs(r)))])
const exitChoices=computed(()=>{if(!props.rules.length)return [];const choices=egressChoices(props.nodes,props.egressGroups||[],ingressIDs.value[0]||0,hasUDP.value?'udp':'tcp');return choices.filter(o=>props.rules.every(r=>ruleNodeIDs(r).every(nid=>egressChoices(props.nodes,props.egressGroups||[],nid,r.protocol||'tcp').some(v=>v.value===o.value))))})
const selectedEgress=computed({get:()=>form.egress_node_id==null&&form.egress_group_id==null?undefined:egressValue(form.egress_node_id,form.egress_group_id),set:(v:string|undefined)=>{delete form.egress_node_id;delete form.egress_group_id;if(v){const x=splitEgress(v);if(x.egress_group_id)form.egress_group_id=x.egress_group_id;else form.egress_node_id=x.egress_node_id}}})
watch(exitChoices,()=>{if(selectedEgress.value&&!exitChoices.value.some(o=>o.value===selectedEgress.value))selectedEgress.value=undefined})
function rowExitChoices(i:number){const row=entryRows.value[i];if(!row?.node_id)return [];return egressChoices(props.nodes,props.egressGroups||[],row.node_id,hasUDP.value?'udp':'tcp').filter(o=>props.rules.every(r=>egressChoices(props.nodes,props.egressGroups||[],row.node_id,r.protocol||'tcp').some(v=>v.value===o.value)))}
function rowEgress(i:number){return entryRows.value[i]?.egress||'node:0'}
function setRowEgress(i:number,v:string){if(v)entryRows.value[i].egress=v}
function selectRowIngress(i:number,id:number|undefined){const row=entryRows.value[i];row.node_id=id||0;if(!row.node_id){row.egress='node:0';return}if(!rowExitChoices(i).some(o=>o.value===row.egress))row.egress=rowExitChoices(i)[0]?.value||'node:0'}
function addEntry(){if(entryRows.value.length<16)entryRows.value.push({node_id:0,egress:'node:0'})}
function removeEntry(i:number){entryRows.value.splice(i,1);if(!entryRows.value.length)entryRows.value.push({node_id:0,egress:'node:0'})}
function submit(){
 if(props.busy)return
 const patch:RuleBatchPatch={}
 if(!hasSharedTLS.value){
  const rows=entryRows.value.filter(r=>r.node_id)
  if(new Set(rows.map(r=>r.node_id)).size!==rows.length){ElMessage.warning('入口节点不能重复');return}
  if(rows.some(r=>!rowIngressAllowed(r.node_id))){ElMessage.warning('所选入口禁止创建新的 UDP 入站规则');return}
  if(rows.length&&rowKey(rows)!==initialEntries)patch.entries=rows.map(r=>({node_id:r.node_id,...splitEgress(r.egress)}))
 }else if(selectedEgress.value){const x=splitEgress(selectedEgress.value);patch.egress_node_id=x.egress_node_id;patch.egress_group_id=x.egress_group_id}
 for(const key of ['listen_port','balance','proxy_accept_enabled','proxy_send_enabled'] as const){
  const value=form[key]
  if(value!==undefined&&value!==null&&value!=='')Object.assign(patch,{[key]:value})
 }
 if(!Object.keys(patch).length){ElMessage.warning('请选择至少一个需要更新的字段');return}
 emit('save',{ids:props.rules.map(r=>r.id),patch})
}
</script>

<template>
 <el-dialog :model-value="modelValue" @update:model-value="emit('update:modelValue',$event)" :title="`批量编辑 ${rules.length} 条规则`" width="480px" top="6vh" class="managed-form-dialog" :close-on-click-modal="!busy" :close-on-press-escape="!busy" :show-close="!busy">
  <p class="subtle">留空保持原值。保存后由节点同步生效，受影响的现有连接可能断开。</p>
  <el-form label-position="top" :disabled="busy" @submit.prevent="submit">
   <el-form-item v-if="!hasSharedTLS" label="入口与出口（可多入口，不改则保持原值）">
    <div class="entry-rows">
     <div v-for="(row,i) in entryRows" :key="i" class="entry-row">
      <el-select :model-value="row.node_id || undefined" @update:model-value="selectRowIngress(i,$event)" placeholder="请选择入口节点" :data-testid="`batch-rule-entry-ingress-${i}`">
       <el-option v-for="n in ingressNodes" :key="n.id" :label="n.name+(rowIngressAllowed(n.id)?'':'（禁止新增 UDP 入站）')" :value="n.id" :disabled="!rowIngressAllowed(n.id)||entryRows.some((r,j)=>j!==i&&r.node_id===n.id)"/>
      </el-select>
      <EgressSelect :model-value="rowEgress(i)" @update:model-value="setRowEgress(i,$event)" :options="rowExitChoices(i)" :disabled="!row.node_id" :data-testid="`batch-rule-entry-egress-${i}`"/>
      <el-button v-if="entryRows.length>1" link type="danger" @click="removeEntry(i)">移除</el-button>
     </div>
     <el-button v-if="entryRows.length<16" @click="addEntry" data-testid="batch-rule-add-entry"><Icon name="add"/>添加入口</el-button>
     <span class="field-tip">每个入口可单独选择出口。入口集合变化时重新分配共享监听端口，未变化时保留端口；多入口共用同一监听端口。选中规则的入口不一致时需填写完整入口，留空则保持原入口。</span>
    </div>
   </el-form-item>
   <el-form-item v-else label="出口（留空不更新）">
    <EgressSelect v-model="selectedEgress" :options="exitChoices" clearable @clear="selectedEgress=undefined" placeholder="保持原出口" data-testid="batch-rule-egress"/>
    <span class="field-tip">共享 TLS 规则仅支持单个入口，迁移入口请逐条编辑。</span>
   </el-form-item>
   <el-form-item label="监听端口（留空不更新，0 为随机分配）"><el-input :model-value="form.listen_port ?? ''" @update:model-value="form.listen_port=$event===''?undefined:Number($event)||0" @clear="clearField('listen_port')" clearable placeholder="保持原端口" type="number" :min="0" :max="65535" /><span class="field-tip">多入口规则共用同一监听端口，须落在所有入口的端口范围交集中。</span></el-form-item>
   <el-collapse v-model="advanced">
    <el-collapse-item title="高级选项（留空不更新）" name="advanced">
     <el-form-item label="负载均衡策略">
      <el-select v-model="form.balance" clearable @clear="clearField('balance')" placeholder="保持原策略" data-testid="batch-rule-balance">
       <el-option label="随机" value="random"/><el-option label="轮询" value="round_robin"/><el-option label="最少连接" value="least_connections"/>
      </el-select>
     </el-form-item>
     <el-form-item label="接受 Proxy Protocol">
      <el-select v-model="form.proxy_accept_enabled" clearable @clear="clearField('proxy_accept_enabled')" placeholder="保持原设置" :disabled="hasSharedTLS" data-testid="batch-rule-proxy-accept">
       <el-option label="关闭" :value="false"/><el-option label="开启" :value="true" :disabled="hasUDP"/>
      </el-select>
      <span v-if="hasSharedTLS" class="field-tip">共享 TLS 入站的接收设置由管理员统一配置。</span>
     </el-form-item>
     <el-form-item label="发送 Proxy Protocol">
      <el-select v-model="form.proxy_send_enabled" clearable @clear="clearField('proxy_send_enabled')" placeholder="保持原设置" data-testid="batch-rule-proxy-send">
       <el-option label="关闭" :value="false"/><el-option label="开启" :value="true" :disabled="hasUDP"/>
      </el-select>
      <span v-if="hasUDP" class="field-tip">所选规则包含 UDP，只能保持或关闭 Proxy Protocol。</span>
     </el-form-item>
     <p class="field-tip">{{limitsLabel}}</p>
    </el-collapse-item>
   </el-collapse>
  </el-form>
  <div class="batch-state-actions">
   <el-button :disabled="busy" @click="emit('toggle',{ids:rules.map(r=>r.id),enabled:false})"><Icon name="pause"/>暂停选中规则</el-button>
   <el-button :disabled="busy" @click="emit('toggle',{ids:rules.map(r=>r.id),enabled:true})"><Icon name="play"/>恢复选中规则</el-button>
  </div>
  <template #footer><el-button :disabled="busy" @click="emit('update:modelValue',false)">取消</el-button><el-button type="primary" :loading="busy" @click="submit">确定</el-button></template>
 </el-dialog>
</template>

<style scoped>
.batch-state-actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:18px}
.batch-state-actions .el-button{margin-left:0}
</style>
