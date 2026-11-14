package control

import (
	"context"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

var dashboardLocation = time.FixedZone("UTC+8", 8*3600)

type dashboardStats struct {
	Users        int64 `json:"users"`
	NewUsers     int64 `json:"new_users"`
	Nodes        int64 `json:"nodes"`
	EnabledNodes int64 `json:"enabled_nodes"`
	OnlineNodes  int64 `json:"online_nodes"`
	OfflineNodes int64 `json:"offline_nodes"`
	Rules        int64 `json:"rules"`
	Connections  int64 `json:"connections"`
	TodayTraffic int64 `json:"today_traffic"`
}
type dashboardTrafficPoint struct {
	At    int64 `json:"at"`
	Bytes int64 `json:"bytes"`
}
type dashboardNode struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	Online  bool   `json:"online"`
}
type dashboardResponse struct {
	Generated time.Time               `json:"generated_at"`
	Timezone  string                  `json:"timezone"`
	Range     string                  `json:"range"`
	Unit      string                  `json:"unit"`
	Stats     dashboardStats          `json:"stats"`
	Traffic   []dashboardTrafficPoint `json:"traffic"`
	Nodes     []dashboardNode         `json:"nodes"`
}

func (s *Server) adminDashboard(w http.ResponseWriter, r *http.Request) {
	if !admin(w, r) {
		return
	}
	period := r.URL.Query().Get("range")
	if period == "" {
		period = "24h"
	}
	if period != "24h" && period != "7d" && period != "30d" {
		fail(w, 400, "时间范围须为 24h、7d 或 30d")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	tx, err := s.Pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		s.dbError(w, err)
		return
	}
	defer tx.Rollback(ctx)
	now := time.Now()
	local := now.In(dashboardLocation)
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, dashboardLocation)
	out := dashboardResponse{Generated: now, Timezone: "Asia/Shanghai", Range: period, Unit: "bytes", Traffic: []dashboardTrafficPoint{}, Nodes: []dashboardNode{}}
	v := &out.Stats
	err = tx.QueryRow(ctx, `SELECT
 (SELECT count(*) FROM users),(SELECT count(*) FROM users WHERE created_at>=$2 AND created_at<=$1),
 (SELECT count(*) FROM nodes),(SELECT count(*) FROM nodes WHERE enabled),
 (SELECT count(*) FROM nodes WHERE enabled AND last_seen>$1::timestamptz-interval '12 seconds'),
 (SELECT count(*) FROM nodes WHERE enabled AND (last_seen IS NULL OR last_seen<=$1::timestamptz-interval '12 seconds')),
 (SELECT count(*) FROM rules),COALESCE((SELECT LEAST(COALESCE(sum(active_connections)::numeric,0),9223372036854775807)::bigint FROM nodes WHERE enabled AND last_seen>$1::timestamptz-interval '12 seconds'),0),
 COALESCE((SELECT LEAST(COALESCE(sum(traffic_bytes)::numeric,0),9223372036854775807)::bigint FROM usage_events WHERE created_at>=$2),0)`,
		now, day).Scan(&v.Users, &v.NewUsers, &v.Nodes, &v.EnabledNodes, &v.OnlineNodes, &v.OfflineNodes, &v.Rules, &v.Connections, &v.TodayTraffic)
	if err != nil {
		s.dbError(w, err)
		return
	}
	var rows pgx.Rows
	if period == "24h" {
		rows, err = tx.Query(ctx, `SELECT date_trunc('hour',created_at),LEAST(COALESCE(sum(traffic_bytes)::numeric,0),9223372036854775807)::bigint FROM usage_events WHERE created_at>=date_trunc('hour',now())-interval '23 hours' GROUP BY 1 ORDER BY 1`)
	} else {
		days := 7
		if period == "30d" {
			days = 30
		}
		rows, err = tx.Query(ctx, `SELECT (created_at AT TIME ZONE 'Asia/Shanghai')::date,LEAST(COALESCE(sum(traffic_bytes)::numeric,0),9223372036854775807)::bigint FROM usage_events WHERE created_at>=$1 GROUP BY 1 ORDER BY 1`, day.AddDate(0, 0, -days+1))
	}
	if err != nil {
		s.dbError(w, err)
		return
	}
	for rows.Next() {
		var at time.Time
		var point dashboardTrafficPoint
		if err = rows.Scan(&at, &point.Bytes); err != nil {
			rows.Close()
			s.dbError(w, err)
			return
		}
		point.At = at.Unix()
		out.Traffic = append(out.Traffic, point)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		s.dbError(w, err)
		return
	}
	rows, err = tx.Query(ctx, `SELECT id,name,enabled,COALESCE(enabled AND last_seen>$1::timestamptz-interval '12 seconds',false) FROM nodes ORDER BY (enabled AND (last_seen IS NULL OR last_seen<=$1::timestamptz-interval '12 seconds')) DESC,enabled DESC,name,id LIMIT 5`, now)
	if err != nil {
		s.dbError(w, err)
		return
	}
	for rows.Next() {
		var n dashboardNode
		if err = rows.Scan(&n.ID, &n.Name, &n.Enabled, &n.Online); err != nil {
			rows.Close()
			s.dbError(w, err)
			return
		}
		out.Nodes = append(out.Nodes, n)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		s.dbError(w, err)
		return
	}
	if err = tx.Commit(ctx); err != nil {
		s.dbError(w, err)
		return
	}
	writeJSON(w, 200, out)
}
