package control

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
)

func nodeLinkFixture(t *testing.T, f *securityFixture, name string) int64 {
	t.Helper()
	v := NodeInput{Name: name, Enabled: true, IngressEnabled: true, AllowDirect: true, TunnelProtocol: "plain_tcp", TunnelListenHost: "0.0.0.0", ListenHost: "0.0.0.0", PortMin: 1024, PortMax: 65535, MaxConnections: 1000, DialTimeoutSeconds: 8, IdleTimeoutSeconds: 300, UDPIdleTimeoutSeconds: 60}
	w := f.request(f.admin, "admin/nodes", "POST", v)
	securityStatus(t, w, 200)
	var result struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		f.p.Exec(context.Background(), "DELETE FROM rules WHERE node_id=$1 OR egress_node_id=$1", result.ID)
		f.p.Exec(context.Background(), "DELETE FROM nodes WHERE id=$1", result.ID)
	})
	return result.ID
}

func exitNodeInput(t *testing.T, f *securityFixture, id int64, allowed []int64) NodeInput {
	t.Helper()
	loaded, _, err := loadNodeInput(context.Background(), f.p, id)
	if err != nil {
		t.Fatal(err)
	}
	loaded.IngressEnabled = false
	loaded.TunnelExitEnabled = true
	loaded.TunnelProtocol = "plain_tcp"
	loaded.TunnelListenHost = "0.0.0.0"
	loaded.TunnelListenPort = 25000
	loaded.TunnelPublicHost = "127.0.0.1"
	loaded.AllowedIngressIDs = allowed
	return loaded
}

func TestExitNodeAllowAllIngressKeepsRuleLinks(t *testing.T) {
	f := newSecurityFixture(t)
	ctx := context.Background()
	ingress := nodeLinkFixture(t, f, "link-ingress-"+Secret())
	exit := nodeLinkFixture(t, f, "link-exit-"+Secret())

	create := exitNodeInput(t, f, exit, []int64{ingress})
	w := f.request(f.admin, fmt.Sprintf("admin/nodes/%d", exit), "PUT", create)
	securityStatus(t, w, 200)

	if _, err := f.p.Exec(ctx, `INSERT INTO rules(user_id,node_id,egress_node_id,listen_port,target_host,target_port,name) VALUES($1,$2,$3,26000,'127.0.0.1',80,'link-rule')`, f.admin, ingress, exit); err != nil {
		t.Fatal(err)
	}

	// Clearing the allowlist switches the exit to "any ingress". It is not a
	// removal of the association that the rule depends on, so the save must
	// succeed and the tunnel link must survive.
	allowAll := exitNodeInput(t, f, exit, []int64{})
	securityStatus(t, f.request(f.admin, fmt.Sprintf("admin/nodes/%d", exit), "PUT", allowAll), 200)

	var allow bool
	var links int
	if err := f.p.QueryRow(ctx, "SELECT tunnel_exit_allow_all_ingress,(SELECT count(*) FROM node_tunnel_links WHERE egress_node_id=$1) FROM nodes WHERE id=$1", exit).Scan(&allow, &links); err != nil {
		t.Fatal(err)
	}
	if !allow || links != 1 {
		t.Fatalf("allow-all save lost the rule link: allow=%v links=%d", allow, links)
	}
}

func TestExitNodeRemovingIngressKeepsRuleLinksAndReportsThem(t *testing.T) {
	f := newSecurityFixture(t)
	ctx := context.Background()
	ingress := nodeLinkFixture(t, f, "link-ingress-"+Secret())
	other := nodeLinkFixture(t, f, "link-other-"+Secret())
	exit := nodeLinkFixture(t, f, "link-exit-"+Secret())

	securityStatus(t, f.request(f.admin, fmt.Sprintf("admin/nodes/%d", exit), "PUT", exitNodeInput(t, f, exit, []int64{ingress, other})), 200)
	if _, err := f.p.Exec(ctx, `INSERT INTO rules(user_id,node_id,egress_node_id,listen_port,target_host,target_port,name) VALUES($1,$2,$3,26001,'127.0.0.1',80,'link-rule')`, f.admin, ingress, exit); err != nil {
		t.Fatal(err)
	}

	w := f.request(f.admin, fmt.Sprintf("admin/nodes/%d", exit), "PUT", exitNodeInput(t, f, exit, []int64{other}))
	securityStatus(t, w, 200)
	var saved struct {
		Retained []int64 `json:"retained_ingress_ids"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &saved); err != nil {
		t.Fatal(err)
	}
	if len(saved.Retained) != 1 || saved.Retained[0] != ingress {
		t.Fatalf("missing retained ingress in response: %s", w.Body.String())
	}
	var links int
	if err := f.p.QueryRow(ctx, "SELECT count(*) FROM node_tunnel_links WHERE egress_node_id=$1 AND ingress_node_id=$2", exit, ingress).Scan(&links); err != nil {
		t.Fatal(err)
	}
	if links != 1 {
		t.Fatal("in-use ingress link was deleted")
	}

	// Once no rule depends on the link, the next save drops it.
	if _, err := f.p.Exec(ctx, "DELETE FROM rules WHERE node_id=$1", ingress); err != nil {
		t.Fatal(err)
	}
	w = f.request(f.admin, fmt.Sprintf("admin/nodes/%d", exit), "PUT", exitNodeInput(t, f, exit, []int64{other}))
	securityStatus(t, w, 200)
	if err := json.Unmarshal(w.Body.Bytes(), &saved); err != nil {
		t.Fatal(err)
	}
	if len(saved.Retained) != 0 {
		t.Fatalf("retained list should be empty: %s", w.Body.String())
	}
	if err := f.p.QueryRow(ctx, "SELECT count(*) FROM node_tunnel_links WHERE egress_node_id=$1 AND ingress_node_id=$2", exit, ingress).Scan(&links); err != nil {
		t.Fatal(err)
	}
	if links != 0 {
		t.Fatal("unused ingress link was not removed")
	}
}
