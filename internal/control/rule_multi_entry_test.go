package control

import (
	"context"
	"encoding/json"
	"testing"

	pb "github.com/nekopass/nekopass/internal/protocol"
)

func multiEntryNodes(t *testing.T, f *securityFixture) (entryA, entryB, exitA, exitB int64) {
	t.Helper()
	ctx := context.Background()
	mkNode := func(portMin, portMax int) int64 {
		var id int64
		if err := f.p.QueryRow(ctx, `INSERT INTO nodes(name,token_hash,port_min,port_max) VALUES($1,$2,$3,$4) RETURNING id`, Secret(), Secret(), portMin, portMax).Scan(&id); err != nil {
			t.Fatal(err)
		}
		testAuthorize(t, f.p, f.user, id)
		return id
	}
	entryA = mkNode(20000, 30000)
	entryB = mkNode(25000, 35000)
	mkExit := func() int64 {
		var id int64
		if err := f.p.QueryRow(ctx, `INSERT INTO nodes(name,token_hash,tunnel_exit_enabled,tunnel_public_host,tunnel_listen_port,protocol_version) VALUES($1,$2,true,'exit.example.test',24443,30) RETURNING id`, Secret(), Secret()).Scan(&id); err != nil {
			t.Fatal(err)
		}
		testAuthorize(t, f.p, f.user, id)
		return id
	}
	exitA = mkExit()
	exitB = mkExit()
	link := func(ingress, egress int64) {
		if _, err := f.p.Exec(ctx, `INSERT INTO node_tunnel_links(ingress_node_id,egress_node_id,token) VALUES($1,$2,$3)`, ingress, egress, Secret()); err != nil {
			t.Fatal(err)
		}
	}
	link(entryA, exitA)
	link(entryB, exitB)
	t.Cleanup(func() {
		for _, n := range []int64{entryA, entryB, exitA, exitB} {
			f.p.Exec(ctx, "DELETE FROM rule_usage WHERE node_id=$1", n)
			f.p.Exec(ctx, "DELETE FROM grants WHERE node_id=$1", n)
			f.p.Exec(ctx, "DELETE FROM rules WHERE node_id=$1", n)
			f.p.Exec(ctx, "DELETE FROM rule_entries WHERE node_id=$1", n)
		}
		f.p.Exec(ctx, "DELETE FROM rules WHERE user_id=$1", f.user)
		for _, n := range []int64{entryA, entryB, exitA, exitB} {
			f.p.Exec(ctx, "DELETE FROM nodes WHERE id=$1", n)
		}
	})
	return entryA, entryB, exitA, exitB
}

func createRule(t *testing.T, f *securityFixture, in RuleInput) int64 {
	t.Helper()
	w := f.request(f.user, "rules", "POST", in)
	if w.Code != 200 {
		t.Fatalf("create rule: %d %s", w.Code, w.Body.String())
	}
	var created struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	return created.ID
}

func TestMultiEntrySharedPortDistinctEgress(t *testing.T) {
	f := newSecurityFixture(t)
	ctx := context.Background()
	entryA, entryB, exitA, exitB := multiEntryNodes(t, f)

	rid := createRule(t, f, RuleInput{
		Protocol: "tcp",
		Targets:  []string{"127.0.0.1:443"},
		Enabled:  true,
		Entries: []RuleEntryInput{
			{NodeID: entryA, EgressNodeID: exitA},
			{NodeID: entryB, EgressNodeID: exitB},
		},
	})
	var port int
	var count int
	if err := f.p.QueryRow(ctx, "SELECT listen_port FROM rules WHERE id=$1", rid).Scan(&port); err != nil {
		t.Fatal(err)
	}
	if port < 25000 || port > 30000 {
		t.Fatalf("shared port %d not in intersection 25000-30000", port)
	}
	if err := f.p.QueryRow(ctx, "SELECT count(*) FROM rule_entries WHERE rule_id=$1", rid).Scan(&count); err != nil || count != 2 {
		t.Fatalf("entries=%d err=%v", count, err)
	}
	if err := f.p.QueryRow(ctx, "SELECT count(*) FROM rule_ports WHERE rule_id=$1", rid).Scan(&count); err != nil || count != 2 {
		t.Fatalf("rule_ports=%d err=%v", count, err)
	}

	// Each ingress syncs its own egress.
	stream := &StreamServer{Server: f.s}
	instances := map[int64]string{}
	exchange := func(id int64) *pb.ControlMessage {
		t.Helper()
		if instances[id] == "" {
			instances[id] = Secret()
		}
		c, err := stream.exchange(ctx, f.p, id, &pb.AgentMessage{ProtocolVersion: 30, InstanceId: instances[id]})
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	a := exchange(entryA)
	if len(a.Rules) != 1 || a.Rules[0].ListenPort != int32(port) || a.Rules[0].EgressNodeId != exitA || a.Rules[0].IngressNodeId != entryA {
		t.Fatalf("ingress A sync wrong: %+v", a.Rules)
	}
	b := exchange(entryB)
	if len(b.Rules) != 1 || b.Rules[0].ListenPort != int32(port) || b.Rules[0].EgressNodeId != exitB || b.Rules[0].IngressNodeId != entryB {
		t.Fatalf("ingress B sync wrong: %+v", b.Rules)
	}
	// Egress side grants resolve per ingress.
	if len(exchange(exitA).EgressRules) != 1 || exchange(exitA).EgressRules[0].IngressNodeId != entryA {
		t.Fatal("egress A grant wrong")
	}
	if len(exchange(exitB).EgressRules) != 1 || exchange(exitB).EgressRules[0].IngressNodeId != entryB {
		t.Fatal("egress B grant wrong")
	}

	// Manual port outside the intersection is rejected.
	w := f.request(f.user, "rules", "POST", RuleInput{
		Protocol: "tcp", Targets: []string{"127.0.0.1:443"}, ListenPort: 21000, Enabled: true,
		Entries: []RuleEntryInput{{NodeID: entryA}, {NodeID: entryB}},
	})
	securityStatus(t, w, 400)

	// Batch egress update applies to every entry; batch ingress switch is rejected.
	var zero int64
	securityStatus(t, f.request(f.user, "rules/batch", "POST", BatchInput{Action: "edit", IDs: []int64{rid}, Patch: &RuleBatchPatch{EgressNodeID: &zero}}), 200)
	if err := f.p.QueryRow(ctx, "SELECT count(*) FROM rule_entries WHERE rule_id=$1 AND egress_node_id IS NULL", rid).Scan(&count); err != nil || count != 2 {
		t.Fatalf("batch egress not applied to all entries: %d %v", count, err)
	}
	securityStatus(t, f.request(f.user, "rules/batch", "POST", BatchInput{Action: "edit", IDs: []int64{rid}, Patch: &RuleBatchPatch{NodeID: &entryA}}), 400)

	// Duplicate and unknown ingress rejected.
	securityStatus(t, f.request(f.user, "rules", "POST", RuleInput{
		Protocol: "tcp", Targets: []string{"127.0.0.1:443"},
		Entries: []RuleEntryInput{{NodeID: entryA}, {NodeID: entryA}},
	}), 400)
}

func TestMultiEntryAdmissionPolicies(t *testing.T) {
	f := newSecurityFixture(t)
	ctx := context.Background()
	entryA, entryB, exitA, _ := multiEntryNodes(t, f)

	// Disjoint port ranges cannot share a port.
	var narrow int64
	if err := f.p.QueryRow(ctx, `INSERT INTO nodes(name,token_hash,port_min,port_max) VALUES($1,$2,40000,41000) RETURNING id`, Secret(), Secret()).Scan(&narrow); err != nil {
		t.Fatal(err)
	}
	testAuthorize(t, f.p, f.user, narrow)
	t.Cleanup(func() {
		f.p.Exec(ctx, "DELETE FROM nodes WHERE id=$1", narrow)
	})
	w := f.request(f.user, "rules", "POST", RuleInput{
		Protocol: "tcp", Targets: []string{"127.0.0.1:443"},
		Entries: []RuleEntryInput{{NodeID: entryA}, {NodeID: narrow}},
	})
	securityStatus(t, w, 400)

	// UDP creation denied on a restricted ingress.
	if _, err := f.p.Exec(ctx, "UPDATE nodes SET deny_udp_ingress_creation=true WHERE id=$1", entryB); err != nil {
		t.Fatal(err)
	}
	w = f.request(f.user, "rules", "POST", RuleInput{
		Protocol: "udp", Targets: []string{"127.0.0.1:443"},
		Entries: []RuleEntryInput{{NodeID: entryA}, {NodeID: entryB, EgressNodeID: exitA}},
	})
	securityStatus(t, w, 400)

	// TLS inbound is single-ingress only.
	w = f.request(f.user, "rules", "POST", RuleInput{
		Protocol: "tcp", Targets: []string{"127.0.0.1:443"}, TLSInboundID: 1,
		Entries: []RuleEntryInput{{NodeID: entryA}, {NodeID: entryB}},
	})
	securityStatus(t, w, 400)
}

func TestMultiEntryImportRoundTrip(t *testing.T) {
	f := newSecurityFixture(t)
	ctx := context.Background()
	entryA, entryB, exitA, exitB := multiEntryNodes(t, f)

	// Simulate a Nekopass full-backup row carrying entries.
	backup := RuleInput{
		Protocol: "tcp", Name: "backup-multi", Targets: []string{"127.0.0.1:443"},
		Balance: "random", Enabled: true,
		Entries: []RuleEntryInput{
			{NodeID: entryA, EgressNodeID: exitA},
			{NodeID: entryB, EgressNodeID: exitB},
		},
	}
	w := f.request(f.user, "rules/import", "POST", map[string]any{"rules": []RuleInput{backup}})
	if w.Code != 200 {
		t.Fatalf("import: %d %s", w.Code, w.Body.String())
	}
	var imported struct {
		IDs []int64 `json:"ids"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &imported); err != nil || len(imported.IDs) != 1 {
		t.Fatalf("import ids: %v %v", imported, err)
	}
	rid := imported.IDs[0]
	var count int
	if err := f.p.QueryRow(ctx, "SELECT count(*) FROM rule_entries WHERE rule_id=$1", rid).Scan(&count); err != nil || count != 2 {
		t.Fatalf("imported entries=%d err=%v", count, err)
	}
	var portA, portB int
	if err := f.p.QueryRow(ctx, "SELECT listen_port FROM rules WHERE id=$1", rid).Scan(&portA); err != nil {
		t.Fatal(err)
	}
	// Importing the same backup with fixed ports must conflict, not duplicate.
	tx, err := f.p.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := loadRule(ctx, tx, rid)
	tx.Rollback(ctx)
	if err != nil {
		t.Fatal(err)
	}
	loaded.Name = "backup-multi-copy"
	w = f.request(f.user, "rules/import", "POST", map[string]any{"rules": []RuleInput{loaded}})
	if w.Code != 400 {
		t.Fatalf("duplicate-port import accepted: %d", w.Code)
	}
	// listen_port=0 reallocates a free shared port instead.
	loaded.ListenPort = 0
	loaded.Name = "backup-multi realloc"
	w = f.request(f.user, "rules/import", "POST", map[string]any{"rules": []RuleInput{loaded}})
	if w.Code != 200 {
		t.Fatalf("realloc import: %d %s", w.Code, w.Body.String())
	}
	json.Unmarshal(w.Body.Bytes(), &imported)
	if err := f.p.QueryRow(ctx, "SELECT listen_port FROM rules WHERE id=$1", imported.IDs[0]).Scan(&portB); err != nil {
		t.Fatal(err)
	}
	if portB < 25000 || portB > 30000 {
		t.Fatalf("reallocated port %d outside intersection", portB)
	}
}
