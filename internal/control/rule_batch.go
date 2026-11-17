package control

import (
	"errors"
	"fmt"
)

// Only explicitly supplied fields are changed; false and egress zero are values.
// Ownership, quotas, targets and SNI settings cannot be patched here.
type RuleBatchPatch struct {
	NodeID             *int64           `json:"node_id,omitempty"`
	Entries            []RuleEntryInput `json:"entries,omitempty"`
	EgressGroupID      *int64           `json:"egress_group_id,omitempty"`
	EgressNodeID       *int64           `json:"egress_node_id,omitempty"`
	ListenPort         *int             `json:"listen_port,omitempty"`
	Balance            *string          `json:"balance,omitempty"`
	ProxyAcceptEnabled *bool            `json:"proxy_accept_enabled,omitempty"`
	ProxySendEnabled   *bool            `json:"proxy_send_enabled,omitempty"`
}

func (p *RuleBatchPatch) validate() error {
	if p == nil || p.NodeID == nil && len(p.Entries) == 0 && p.EgressNodeID == nil && p.EgressGroupID == nil && p.ListenPort == nil && p.Balance == nil && p.ProxyAcceptEnabled == nil && p.ProxySendEnabled == nil {
		return errors.New("请选择至少一个需要更新的字段")
	}
	if p.NodeID != nil && len(p.Entries) != 0 {
		return errors.New("入口与多入口列表不能同时提交")
	}
	if p.NodeID != nil && *p.NodeID <= 0 || p.EgressNodeID != nil && *p.EgressNodeID < 0 || p.EgressGroupID != nil && *p.EgressGroupID < 0 || p.EgressGroupID != nil && p.EgressNodeID != nil && *p.EgressGroupID != 0 && *p.EgressNodeID != 0 {
		return errors.New("入口或出口节点无效")
	}
	if len(p.Entries) > 16 {
		return errors.New("单个规则最多支持 16 个入口")
	}
	seen := map[int64]bool{}
	for i, e := range p.Entries {
		if e.NodeID <= 0 || seen[e.NodeID] {
			return errors.New("入口节点无效或重复")
		}
		seen[e.NodeID] = true
		if e.EgressGroupID < 0 || e.EgressGroupID != 0 && e.EgressNodeID != 0 || e.EgressNodeID < 0 || e.EgressNodeID == e.NodeID {
			return fmt.Errorf("第 %d 个入口的出口节点无效", i+1)
		}
	}
	if p.ListenPort != nil && (*p.ListenPort < 0 || *p.ListenPort > 65535 || *p.ListenPort != 0 && *p.ListenPort < 1024) {
		return errors.New("监听端口为 1024–65535，留空或 0 为随机分配")
	}
	if p.Balance != nil && *p.Balance != "random" && *p.Balance != "round_robin" && *p.Balance != "least_connections" {
		return errors.New("负载均衡策略无效")
	}
	return nil
}

func sameEntryNodes(a, b []RuleEntryInput) bool {
	if len(a) != len(b) {
		return false
	}
	seen := make(map[int64]bool, len(a))
	for _, e := range a {
		seen[e.NodeID] = true
	}
	for _, e := range b {
		if !seen[e.NodeID] {
			return false
		}
	}
	return true
}

func (p *RuleBatchPatch) apply(in *RuleInput) error {
	if len(p.Entries) != 0 {
		if in.TLSInboundID != 0 && !sameEntryNodes(in.Entries, p.Entries) {
			return errors.New("共享 TLS 规则切换入口时，请逐条编辑并选择新节点的共享 TLS 入口")
		}
		if !sameEntryNodes(in.Entries, p.Entries) {
			in.ListenPort = 0 // Follow the existing batch ingress-switch allocation policy.
		}
		in.Entries = append([]RuleEntryInput(nil), p.Entries...)
		in.NodeID = in.Entries[0].NodeID
		in.EgressNodeID = in.Entries[0].EgressNodeID
		in.EgressGroupID = in.Entries[0].EgressGroupID
	} else if p.NodeID != nil {
		single := len(in.Entries) == 1 && in.Entries[0].NodeID == *p.NodeID
		if !single {
			if in.TLSInboundID != 0 {
				return errors.New("共享 TLS 规则切换入口时，请逐条编辑并选择新节点的共享 TLS 入口")
			}
			egressNode, egressGroup := in.EgressNodeID, in.EgressGroupID
			for _, e := range in.Entries {
				if e.NodeID == *p.NodeID {
					egressNode, egressGroup = e.EgressNodeID, e.EgressGroupID
					break
				}
			}
			in.NodeID = *p.NodeID
			in.EgressNodeID, in.EgressGroupID = egressNode, egressGroup
			in.Entries = []RuleEntryInput{{NodeID: *p.NodeID, EgressNodeID: egressNode, EgressGroupID: egressGroup}}
			in.ListenPort = 0 // Follow the existing batch ingress-switch allocation policy.
		}
	}
	if p.EgressNodeID != nil || p.EgressGroupID != nil {
		egressNode, egressGroup := in.EgressNodeID, in.EgressGroupID
		if p.EgressNodeID != nil {
			egressNode = *p.EgressNodeID
			egressGroup = 0
		}
		if p.EgressGroupID != nil {
			egressGroup = *p.EgressGroupID
			if egressGroup != 0 {
				egressNode = 0
			}
		}
		in.EgressNodeID, in.EgressGroupID = egressNode, egressGroup
		for i := range in.Entries {
			in.Entries[i].EgressNodeID = egressNode
			in.Entries[i].EgressGroupID = egressGroup
		}
	}
	if p.ListenPort != nil {
		in.ListenPort = *p.ListenPort
	}
	if p.Balance != nil {
		in.Balance = *p.Balance
	}
	if p.ProxyAcceptEnabled != nil {
		if in.TLSInboundID != 0 {
			return errors.New("共享 TLS 入站的 Proxy Protocol 接收由管理员配置")
		}
		if !*p.ProxyAcceptEnabled {
			in.ProxyAccept = "off"
		} else if in.ProxyAccept == "" || in.ProxyAccept == "off" {
			in.ProxyAccept = "auto"
		}
	}
	if p.ProxySendEnabled != nil {
		if !*p.ProxySendEnabled {
			in.ProxySend = "off"
		} else if in.ProxySend == "" || in.ProxySend == "off" {
			in.ProxySend = "v2"
		}
	}
	return nil
}
