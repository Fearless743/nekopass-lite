package agent

import (
	pb "github.com/nekopass/nekopass/internal/protocol"
	"google.golang.org/protobuf/proto"
)

func defaultNodeConfig() *pb.NodeConfig {
	return &pb.NodeConfig{Enabled: true, ListenHost: "0.0.0.0", PortMin: 1024, PortMax: 65535, MaxConnections: 10000, DialTimeoutSeconds: 8, IdleTimeoutSeconds: 300}
}
func (e *Engine) nodeConfiguration() *pb.NodeConfig {
	if c := e.node.Load(); c != nil {
		return proto.Clone(c).(*pb.NodeConfig)
	}
	return defaultNodeConfig()
}
