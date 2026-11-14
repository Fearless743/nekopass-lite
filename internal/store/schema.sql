-- Nekopass schema. Single-file, current-version install.
CREATE TABLE IF NOT EXISTS schema_version (version integer PRIMARY KEY);
INSERT INTO schema_version VALUES (1) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS revision (id integer PRIMARY KEY CHECK(id=1), value bigint NOT NULL);
INSERT INTO revision VALUES(1,1) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS users (
 id bigserial PRIMARY KEY,
 username text NOT NULL UNIQUE,
 password_hash text NOT NULL,
 is_admin boolean NOT NULL DEFAULT false,
 enabled boolean NOT NULL DEFAULT true,
 email_verified_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 quota_epoch bigint NOT NULL DEFAULT 0 CHECK(quota_epoch>=0),
 speed_bps bigint NOT NULL DEFAULT 0 CHECK(speed_bps BETWEEN 0 AND 12500000000),
 quota_bytes bigint NOT NULL DEFAULT 0 CHECK(quota_bytes BETWEEN -1 AND 1152921504606846976),
 max_rules integer NOT NULL DEFAULT 0 CHECK(max_rules BETWEEN 0 AND 10000),
 max_connections bigint NOT NULL DEFAULT 0 CHECK(max_connections BETWEEN 0 AND 1000000),
 ip_limit integer NOT NULL DEFAULT 0 CHECK(ip_limit BETWEEN 0 AND 1000000),
 rule_speed_bps bigint NOT NULL DEFAULT 0 CHECK(rule_speed_bps BETWEEN 0 AND 12500000000),
 rule_ip_limit integer NOT NULL DEFAULT 0 CHECK(rule_ip_limit BETWEEN 0 AND 1000000),
 rule_connection_limit integer NOT NULL DEFAULT 0 CHECK(rule_connection_limit BETWEEN 0 AND 1000000),
 resource_expires_at timestamptz,
 traffic_base_bytes bigint NOT NULL DEFAULT 0 CHECK(traffic_base_bytes BETWEEN 0 AND 1152921504606846976),
 actual_traffic_base_bytes bigint NOT NULL DEFAULT 0 CHECK(actual_traffic_base_bytes>=0),
 resources_revision bigint NOT NULL DEFAULT 0 CHECK(resources_revision>=0)
);
CREATE UNIQUE INDEX IF NOT EXISTS users_verified_email_unique ON users(lower(username)) WHERE email_verified_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS sessions (
 token_hash text PRIMARY KEY, user_id bigint NOT NULL REFERENCES users(id),
 expires_at timestamptz, cookie_renewed_at timestamptz NOT NULL DEFAULT 'epoch'
);
CREATE INDEX IF NOT EXISTS sessions_user_id ON sessions(user_id);

CREATE TABLE IF NOT EXISTS site_settings (
 id integer PRIMARY KEY CHECK(id=1),
 updated_at timestamptz NOT NULL DEFAULT now(),
 config jsonb NOT NULL DEFAULT '{}',
 api_key_hash text NOT NULL DEFAULT '',
 api_key_user_id bigint REFERENCES users(id)
);
INSERT INTO site_settings(id) VALUES(1) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS node_groups (
 id bigserial PRIMARY KEY, name text NOT NULL UNIQUE, description text NOT NULL DEFAULT '',
 enabled boolean NOT NULL DEFAULT true, sort_order integer NOT NULL DEFAULT 0,
 strategy text NOT NULL DEFAULT 'least_connections' CHECK(strategy IN ('least_connections','round_robin','random')),
 health_interval_seconds integer NOT NULL DEFAULT 5 CHECK(health_interval_seconds BETWEEN 2 AND 60),
 health_failures integer NOT NULL DEFAULT 3 CHECK(health_failures BETWEEN 1 AND 20),
 health_successes integer NOT NULL DEFAULT 2 CHECK(health_successes BETWEEN 1 AND 20)
);

CREATE TABLE IF NOT EXISTS nodes (
 id bigserial PRIMARY KEY, name text NOT NULL UNIQUE,
 token_hash text NOT NULL UNIQUE, token text NOT NULL DEFAULT '',
 instance_id text NOT NULL DEFAULT '',
 last_seen timestamptz, applied_revision bigint NOT NULL DEFAULT 0,
 sync_error text NOT NULL DEFAULT '', active_connections bigint NOT NULL DEFAULT 0,
 public_address text NOT NULL DEFAULT '',
 enabled boolean NOT NULL DEFAULT true,
 notes text NOT NULL DEFAULT '',
 listen_host text NOT NULL DEFAULT '0.0.0.0',
 port_min integer NOT NULL DEFAULT 1024 CHECK(port_min BETWEEN 1024 AND 65535),
 port_max integer NOT NULL DEFAULT 65535 CHECK(port_max BETWEEN port_min AND 65535),
 max_connections bigint NOT NULL DEFAULT 10000 CHECK(max_connections BETWEEN 0 AND 1000000),
 dial_timeout_seconds integer NOT NULL DEFAULT 8 CHECK(dial_timeout_seconds BETWEEN 1 AND 120),
 idle_timeout_seconds integer NOT NULL DEFAULT 300 CHECK(idle_timeout_seconds BETWEEN 10 AND 86400),
 udp_idle_timeout_seconds integer NOT NULL DEFAULT 60 CHECK(udp_idle_timeout_seconds BETWEEN 10 AND 3600),
 config_revision bigint NOT NULL DEFAULT 0,
 allow_direct boolean NOT NULL DEFAULT true,
 tunnel_exit_enabled boolean NOT NULL DEFAULT false,
 tunnel_protocol text NOT NULL DEFAULT 'plain_tcp' CHECK(tunnel_protocol IN ('plain_tcp','tls_tcp','plain_h2','tls_h2','plain_udp','dtls_udp','random_tcp','random_h2','random_udp','tls_h3')),
 tunnel_listen_host text NOT NULL DEFAULT '0.0.0.0',
 tunnel_listen_port integer NOT NULL DEFAULT 0 CHECK(tunnel_listen_port=0 OR tunnel_listen_port BETWEEN 1 AND 65535),
 tunnel_public_host text NOT NULL DEFAULT '',
 ingress_enabled boolean NOT NULL DEFAULT true,
 tls_config jsonb NOT NULL DEFAULT '{}',
 tls_certificate text NOT NULL DEFAULT '',
 tls_private_key text NOT NULL DEFAULT '',
 tls_ca text NOT NULL DEFAULT '',
 tls_status text NOT NULL DEFAULT 'unconfigured',
 tls_error text NOT NULL DEFAULT '',
 tls_not_after timestamptz,
 tls_generation bigint NOT NULL DEFAULT 0,
 protocol_version integer NOT NULL DEFAULT 0,
 acme_ack bigint NOT NULL DEFAULT 0,
 tls_inbound_only boolean NOT NULL DEFAULT false,
 ingress_rate integer NOT NULL DEFAULT 10000 CHECK(ingress_rate BETWEEN 0 AND 10000000),
 egress_rate integer NOT NULL DEFAULT 0 CHECK(egress_rate BETWEEN 0 AND 10000000),
 random_config jsonb NOT NULL DEFAULT '{"cipher":"chacha20-poly1305","key":""}',
 first_connected_at timestamptz,
 deny_udp_ingress_creation boolean NOT NULL DEFAULT false,
 bandwidth_up_mbps bigint NOT NULL DEFAULT 0 CHECK(bandwidth_up_mbps BETWEEN 0 AND 1000000),
 bandwidth_down_mbps bigint NOT NULL DEFAULT 0 CHECK(bandwidth_down_mbps BETWEEN 0 AND 1000000),
 brutal_enabled boolean NOT NULL DEFAULT false,
 client_tcp_brutal_enabled boolean NOT NULL DEFAULT false,
 mux_config jsonb NOT NULL DEFAULT '{"enabled":false,"max_connections":0,"max_streams":128,"idle_timeout_seconds":60}'
);
CREATE TABLE IF NOT EXISTS node_group_members (
 group_id bigint NOT NULL REFERENCES node_groups(id) ON DELETE CASCADE,
 node_id bigint NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
 weight integer NOT NULL DEFAULT 1 CHECK(weight>0 AND weight<=1000), priority integer NOT NULL DEFAULT 0,
 role text NOT NULL DEFAULT 'active' CHECK(role IN ('active','standby','disabled')),
 PRIMARY KEY(group_id,node_id)
);
CREATE TABLE IF NOT EXISTS node_tunnel_links (
 ingress_node_id bigint NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
 egress_node_id bigint NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
 token text NOT NULL,
 PRIMARY KEY(ingress_node_id,egress_node_id),
 CHECK(ingress_node_id<>egress_node_id)
);
CREATE TABLE IF NOT EXISTS node_install_tickets (
 token_hash text PRIMARY KEY,
 node_id bigint NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
 expires_at timestamptz NOT NULL,
 used_at timestamptz,
 config jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS node_install_tickets_expiry ON node_install_tickets(expires_at);

CREATE TABLE IF NOT EXISTS node_tls_inbounds (
 id bigserial PRIMARY KEY,node_id bigint NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
 config jsonb NOT NULL,port integer NOT NULL CHECK(port BETWEEN 1 AND 65535),
 certificate text NOT NULL DEFAULT '',private_key text NOT NULL DEFAULT '',
 certificate_status text NOT NULL DEFAULT 'unconfigured',certificate_error text NOT NULL DEFAULT '',
 not_after timestamptz,generation bigint NOT NULL DEFAULT 1,
 UNIQUE(node_id,id),UNIQUE(node_id,port)
);
CREATE TABLE IF NOT EXISTS inbound_acme_accounts (
 inbound_id bigint PRIMARY KEY REFERENCES node_tls_inbounds(id) ON DELETE CASCADE,
 directory_url text NOT NULL,email text NOT NULL,private_key text NOT NULL,registration jsonb NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS node_acme_accounts (
 node_id bigint PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
 directory_url text NOT NULL, email text NOT NULL, private_key text NOT NULL,
 registration jsonb NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS node_acme_challenges (
 node_id bigint NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
 domain text NOT NULL, token text NOT NULL, key_authorization text NOT NULL,
 expires_at timestamptz NOT NULL, revision bigint NOT NULL,
 inbound_id bigint REFERENCES node_tls_inbounds(id) ON DELETE CASCADE,
 PRIMARY KEY(node_id,token)
);

CREATE TABLE IF NOT EXISTS rule_groups (
 id bigserial PRIMARY KEY, user_id bigint NOT NULL REFERENCES users(id),
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 64), UNIQUE(user_id,name)
);
CREATE TABLE IF NOT EXISTS rules (
 id bigserial PRIMARY KEY, user_id bigint NOT NULL REFERENCES users(id),
 node_id bigint NOT NULL REFERENCES nodes(id), listen_host text NOT NULL DEFAULT '0.0.0.0',
 listen_port integer NOT NULL,
 target_host text NOT NULL, target_port integer NOT NULL CHECK(target_port BETWEEN 1 AND 65535),
 enabled boolean NOT NULL DEFAULT true,
 name text NOT NULL DEFAULT '',
 group_id bigint REFERENCES rule_groups(id) ON DELETE SET NULL,
 targets jsonb NOT NULL DEFAULT '[]',
 balance text NOT NULL DEFAULT 'random' CHECK(balance IN ('random','round_robin','least_connections')),
 speed_mbps bigint NOT NULL DEFAULT 0 CHECK(speed_mbps BETWEEN 0 AND 100000),
 ip_limit integer NOT NULL DEFAULT 0 CHECK(ip_limit BETWEEN 0 AND 1000000),
 connection_limit integer NOT NULL DEFAULT 0 CHECK(connection_limit BETWEEN 0 AND 1000000),
 proxy_accept text NOT NULL DEFAULT 'off' CHECK(proxy_accept IN ('off','v1','v2','auto')),
 proxy_send text NOT NULL DEFAULT 'off' CHECK(proxy_send IN ('off','v1','v2')),
 proxy_trusted_cidrs jsonb NOT NULL DEFAULT '[]',
 traffic_baseline bigint NOT NULL DEFAULT 0,
 config_revision bigint NOT NULL DEFAULT 0,
 egress_node_id bigint REFERENCES nodes(id),
 egress_group_id bigint REFERENCES node_groups(id),
 protocol text NOT NULL DEFAULT 'tcp' CHECK(protocol IN ('tcp','udp')),
 tls_inbound_id bigint,
 sni_names jsonb NOT NULL DEFAULT '[]',
 tls_alpn jsonb NOT NULL DEFAULT '[]',
 origin_tls jsonb NOT NULL DEFAULT '{}',
 CHECK(egress_node_id IS NULL OR egress_group_id IS NULL),
 CHECK(
  (tls_inbound_id IS NULL AND listen_port BETWEEN 1024 AND 65535)
  OR (tls_inbound_id IS NOT NULL AND listen_port=0 AND protocol='tcp' AND jsonb_array_length(sni_names) BETWEEN 1 AND 32)),
 FOREIGN KEY(node_id,tls_inbound_id) REFERENCES node_tls_inbounds(node_id,id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX IF NOT EXISTS rules_egress_node_id ON rules(egress_node_id);
CREATE INDEX IF NOT EXISTS rules_egress_group ON rules(egress_group_id) WHERE egress_group_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS rule_entries (
 id bigserial PRIMARY KEY, rule_id bigint NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
 node_id bigint NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
 egress_node_id bigint REFERENCES nodes(id) ON DELETE SET NULL,
 egress_group_id bigint REFERENCES node_groups(id) ON DELETE SET NULL,
 UNIQUE(rule_id,node_id),
 CHECK(egress_node_id IS NULL OR egress_group_id IS NULL)
);
CREATE INDEX IF NOT EXISTS rule_entries_node ON rule_entries(node_id);
CREATE INDEX IF NOT EXISTS rule_entries_egress_node ON rule_entries(egress_node_id);
CREATE INDEX IF NOT EXISTS rule_entries_egress_group ON rule_entries(egress_group_id) WHERE egress_group_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS rule_ports (
 node_id bigint NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
 protocol text NOT NULL CHECK(protocol IN ('tcp','udp')),
 listen_port integer NOT NULL,
 rule_id bigint REFERENCES rules(id) ON DELETE CASCADE,
 tls_inbound_id bigint REFERENCES node_tls_inbounds(id) ON DELETE CASCADE,
 PRIMARY KEY(node_id,protocol,listen_port),
 CHECK(num_nonnulls(rule_id,tls_inbound_id)=1)
);
CREATE INDEX IF NOT EXISTS rule_ports_owner ON rule_ports(rule_id);
CREATE TABLE IF NOT EXISTS rule_sni_names (
 tls_inbound_id bigint NOT NULL REFERENCES node_tls_inbounds(id) ON DELETE CASCADE,
 name text NOT NULL,rule_id bigint NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
 PRIMARY KEY(tls_inbound_id,name)
);

CREATE FUNCTION sync_rule_ports(p_rule_id bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
 v_protocol text; v_port integer; v_tls bigint;
BEGIN
 SELECT protocol,listen_port,tls_inbound_id INTO v_protocol,v_port,v_tls FROM rules WHERE id=p_rule_id;
 IF NOT FOUND THEN RETURN; END IF;
 DELETE FROM rule_ports WHERE rule_id=p_rule_id;
 IF v_tls IS NULL THEN
  IF EXISTS(SELECT 1 FROM rule_entries WHERE rule_id=p_rule_id) THEN
   INSERT INTO rule_ports(node_id,protocol,listen_port,rule_id)
   SELECT e.node_id,v_protocol,v_port,p_rule_id FROM rule_entries e WHERE e.rule_id=p_rule_id;
  ELSE
   INSERT INTO rule_ports(node_id,protocol,listen_port,rule_id)
   SELECT node_id,v_protocol,v_port,p_rule_id FROM rules WHERE id=p_rule_id;
  END IF;
 END IF;
END $$;
CREATE FUNCTION reserve_rule_ports() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 PERFORM sync_rule_ports(NEW.id);
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS reserve_rule_ports ON rules;
CREATE TRIGGER reserve_rule_ports AFTER INSERT OR UPDATE OF node_id,listen_port,protocol,tls_inbound_id ON rules FOR EACH ROW EXECUTE FUNCTION reserve_rule_ports();
CREATE FUNCTION reserve_entry_ports() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN
  PERFORM sync_rule_ports(OLD.rule_id);
  RETURN OLD;
 ELSE
  PERFORM sync_rule_ports(NEW.rule_id);
  RETURN NEW;
 END IF;
END $$;
DROP TRIGGER IF EXISTS reserve_entry_ports_ins ON rule_entries;
DROP TRIGGER IF EXISTS reserve_entry_ports_upd ON rule_entries;
DROP TRIGGER IF EXISTS reserve_entry_ports_del ON rule_entries;
CREATE TRIGGER reserve_entry_ports_ins AFTER INSERT ON rule_entries FOR EACH ROW EXECUTE FUNCTION reserve_entry_ports();
CREATE TRIGGER reserve_entry_ports_upd AFTER UPDATE OF node_id ON rule_entries FOR EACH ROW EXECUTE FUNCTION reserve_entry_ports();
CREATE TRIGGER reserve_entry_ports_del AFTER DELETE ON rule_entries FOR EACH ROW EXECUTE FUNCTION reserve_entry_ports();
CREATE FUNCTION ensure_rule_entry() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO rule_entries(rule_id,node_id,egress_node_id,egress_group_id)
 VALUES(NEW.id,NEW.node_id,NEW.egress_node_id,NEW.egress_group_id)
 ON CONFLICT(rule_id,node_id) DO NOTHING;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS ensure_rule_entry ON rules;
CREATE TRIGGER ensure_rule_entry AFTER INSERT ON rules FOR EACH ROW EXECUTE FUNCTION ensure_rule_entry();
CREATE FUNCTION reserve_tls_inbound_port() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 DELETE FROM rule_ports WHERE tls_inbound_id=NEW.id;
 INSERT INTO rule_ports(node_id,protocol,listen_port,tls_inbound_id) VALUES(NEW.node_id,'tcp',NEW.port,NEW.id);
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS reserve_tls_inbound_port ON node_tls_inbounds;
CREATE TRIGGER reserve_tls_inbound_port AFTER INSERT OR UPDATE OF node_id,port ON node_tls_inbounds FOR EACH ROW EXECUTE FUNCTION reserve_tls_inbound_port();
CREATE FUNCTION reserve_rule_sni() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 DELETE FROM rule_sni_names WHERE rule_id=NEW.id;
 IF NEW.tls_inbound_id IS NOT NULL THEN
  INSERT INTO rule_sni_names(tls_inbound_id,name,rule_id) SELECT NEW.tls_inbound_id,value,NEW.id FROM jsonb_array_elements_text(NEW.sni_names);
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS reserve_rule_sni ON rules;
CREATE TRIGGER reserve_rule_sni AFTER INSERT OR UPDATE OF tls_inbound_id,sni_names ON rules FOR EACH ROW EXECUTE FUNCTION reserve_rule_sni();

CREATE TABLE IF NOT EXISTS grants (
 node_id bigint NOT NULL REFERENCES nodes(id), user_id bigint NOT NULL REFERENCES users(id),
 issued bigint NOT NULL DEFAULT 0, spent bigint NOT NULL DEFAULT 0,
 released bigint NOT NULL DEFAULT 0, traffic bigint NOT NULL DEFAULT 0,
 unlimited_spent bigint NOT NULL DEFAULT 0,
 unlimited_open boolean NOT NULL DEFAULT false,
 quota_epoch bigint NOT NULL DEFAULT 0 CHECK(quota_epoch>=0),
 charged_bytes bigint NOT NULL DEFAULT 0,
 PRIMARY KEY(node_id,user_id,quota_epoch),
 CHECK(spent>=0 AND released>=0 AND traffic>=0 AND unlimited_spent>=0 AND spent::numeric+released<=issued AND charged_bytes>=0 AND charged_bytes::numeric<=spent::numeric+unlimited_spent)
);
CREATE INDEX IF NOT EXISTS grants_user_id_idx ON grants(user_id);
CREATE TABLE IF NOT EXISTS rule_usage (
 node_id bigint NOT NULL REFERENCES nodes(id), rule_id bigint NOT NULL,
 user_id bigint NOT NULL REFERENCES users(id), traffic bigint NOT NULL DEFAULT 0,
 PRIMARY KEY(node_id,rule_id)
);
CREATE TABLE IF NOT EXISTS usage_events (
 id bigserial PRIMARY KEY, node_id bigint NOT NULL, user_id bigint NOT NULL,
 traffic_bytes bigint NOT NULL CHECK(traffic_bytes > 0), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS usage_events_user_time ON usage_events(user_id,created_at);
CREATE TABLE IF NOT EXISTS rule_events (
 id bigserial PRIMARY KEY,node_id bigint NOT NULL,rule_id bigint NOT NULL,user_id bigint NOT NULL,
 traffic_bytes bigint NOT NULL CHECK(traffic_bytes>0),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rule_events_rule_time ON rule_events(rule_id,created_at);
CREATE INDEX IF NOT EXISTS rule_events_user_time ON rule_events(user_id,created_at);

CREATE TABLE IF NOT EXISTS deleted_nodes (
 id bigint PRIMARY KEY,
 name text NOT NULL,
 deleted_at timestamptz NOT NULL DEFAULT now(),
 deleted_by bigint REFERENCES users(id) ON DELETE SET NULL
);
CREATE TABLE IF NOT EXISTS deleted_node_grants (LIKE grants INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
ALTER TABLE deleted_node_grants ADD PRIMARY KEY(node_id,user_id,quota_epoch);
ALTER TABLE deleted_node_grants ADD FOREIGN KEY(node_id) REFERENCES deleted_nodes(id);
ALTER TABLE deleted_node_grants ADD FOREIGN KEY(user_id) REFERENCES users(id);
CREATE INDEX IF NOT EXISTS deleted_node_grants_user_epoch ON deleted_node_grants(user_id,quota_epoch);
CREATE TABLE IF NOT EXISTS deleted_node_rule_usage (LIKE rule_usage INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
ALTER TABLE deleted_node_rule_usage ADD PRIMARY KEY(node_id,rule_id);
ALTER TABLE deleted_node_rule_usage ADD FOREIGN KEY(node_id) REFERENCES deleted_nodes(id);
ALTER TABLE deleted_node_rule_usage ADD FOREIGN KEY(user_id) REFERENCES users(id);
CREATE INDEX IF NOT EXISTS deleted_node_rule_usage_rule ON deleted_node_rule_usage(rule_id);

CREATE VIEW current_grants AS
 SELECT g.* FROM grants g JOIN users u ON u.id=g.user_id AND u.quota_epoch=g.quota_epoch
 UNION ALL
 SELECT g.* FROM deleted_node_grants g JOIN users u ON u.id=g.user_id AND u.quota_epoch=g.quota_epoch;
CREATE VIEW all_rule_usage AS
 SELECT * FROM rule_usage
 UNION ALL
 SELECT * FROM deleted_node_rule_usage;
CREATE VIEW user_entitlements AS
 SELECT u.id,u.username,u.is_admin,u.enabled AS account_enabled,u.enabled,
 u.resource_expires_at AS expires_at,
 u.speed_bps,u.quota_bytes,u.max_rules,u.max_connections,u.ip_limit,
 u.rule_speed_bps,u.rule_ip_limit,u.rule_connection_limit,
 u.quota_epoch,u.traffic_base_bytes,u.resources_revision,u.actual_traffic_base_bytes
 FROM users u;
CREATE TABLE IF NOT EXISTS user_node_groups (
 user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 group_id bigint NOT NULL REFERENCES node_groups(id) ON DELETE CASCADE,
 PRIMARY KEY(user_id,group_id)
);
CREATE VIEW user_nodes AS
 SELECT DISTINCT u.id AS user_id,n.id AS node_id FROM user_entitlements u
 JOIN user_node_groups ug ON ug.user_id=u.id
 JOIN node_groups g ON g.id=ug.group_id AND g.enabled
 JOIN node_group_members m ON m.group_id=g.id
 JOIN nodes n ON n.id=m.node_id AND n.enabled
 WHERE u.enabled AND (u.expires_at IS NULL OR u.expires_at>now());
CREATE VIEW rule_outbound_routes AS
 SELECT r.id AS rule_id,e.node_id AS ingress_node_id,n.id AS egress_node_id,1 AS weight,'active'::text AS role
 FROM rules r JOIN rule_entries e ON e.rule_id=r.id JOIN nodes n ON n.id=e.egress_node_id AND n.enabled AND n.tunnel_exit_enabled
 JOIN node_tunnel_links l ON l.ingress_node_id=e.node_id AND l.egress_node_id=n.id
 JOIN user_nodes a ON a.user_id=r.user_id AND a.node_id=n.id
 WHERE n.id<>e.node_id AND (r.protocol='udp' OR n.tunnel_protocol NOT IN ('plain_udp','dtls_udp','random_udp'))
 UNION ALL
 SELECT r.id,e.node_id,n.id,m.weight,m.role
 FROM rules r JOIN rule_entries e ON e.rule_id=r.id JOIN user_node_groups ug ON ug.user_id=r.user_id AND ug.group_id=e.egress_group_id
 JOIN node_groups g ON g.id=ug.group_id AND g.enabled
 JOIN node_group_members m ON m.group_id=g.id AND m.role<>'disabled'
 JOIN nodes n ON n.id=m.node_id AND n.enabled AND n.tunnel_exit_enabled AND n.id<>e.node_id
 JOIN node_tunnel_links l ON l.ingress_node_id=e.node_id AND l.egress_node_id=n.id
 JOIN user_nodes a ON a.user_id=r.user_id AND a.node_id=n.id
 WHERE r.protocol='udp' OR n.tunnel_protocol NOT IN ('plain_udp','dtls_udp','random_udp');

CREATE TABLE IF NOT EXISTS user_resource_changes (
 id bigserial PRIMARY KEY,user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 actor_id bigint REFERENCES users(id) ON DELETE SET NULL,before_state jsonb NOT NULL,after_state jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS announcements (
 id bigserial PRIMARY KEY, title text NOT NULL, content text NOT NULL,
 published boolean NOT NULL DEFAULT true, sort_order integer NOT NULL DEFAULT 0, legacy boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS announcements_legacy ON announcements(legacy) WHERE legacy;

CREATE TABLE IF NOT EXISTS registration_captchas (
 id text PRIMARY KEY, answer_hash text NOT NULL, remote_key text NOT NULL,
 expires_at timestamptz NOT NULL,
 purpose text NOT NULL DEFAULT 'registration' CHECK(purpose IN ('registration')),
 user_id bigint REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS registration_captchas_expiry ON registration_captchas(expires_at);
CREATE TABLE IF NOT EXISTS registration_codes (
 id text PRIMARY KEY, email text NOT NULL, code_hash text NOT NULL,
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
 sent boolean NOT NULL DEFAULT false, expires_at timestamptz NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS registration_codes_email ON registration_codes(email);
CREATE INDEX IF NOT EXISTS registration_codes_expiry ON registration_codes(expires_at);
