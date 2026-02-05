package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	clientv3 "go.etcd.io/etcd/client/v3"
	"go.etcd.io/etcd/api/v3/mvccpb"
)

const (
	servicePrefix = "/services/backend/"
	haproxyCfg    = "/etc/haproxy/haproxy.cfg"
	tmpCfg        = "/etc/haproxy/haproxy.cfg.tmp"
)

func main() {
	log.SetFlags(log.LstdFlags)

	nodeID := os.Getenv("LB_NODE_ID")
	if nodeID == "" {
		nodeID = "lb-go"
	}

	etcdEndpoint := os.Getenv("ETCD_NODE")
	if etcdEndpoint == "" {
		etcdEndpoint = "http://etcd1:2379"
	}

	log.Printf("[INFO] Starting Load Balancer Node: %s", nodeID)

	cli := waitForEtcd(etcdEndpoint)
	defer cli.Close()

	ctx := context.Background()

	resp, err := cli.Get(ctx, servicePrefix, clientv3.WithPrefix())
	if err != nil {
		log.Fatalf("initial get failed: %v", err)
	}

	log.Printf("[INFO] Found %d backend(s) in etcd", len(resp.Kvs))

	// CHANGE #1: do not start HAProxy with zero backends
	if len(resp.Kvs) > 0 {
		renderAndReload(resp.Kvs)
	} else {
		log.Printf("[INFO] No backends yet, waiting...")
	}

	nextRev := resp.Header.Revision + 1

	go watchLoop(cli, nextRev)

	select {}
}

func waitForEtcd(endpoint string) *clientv3.Client {
	log.Printf("[INFO] Waiting for etcd to be ready...")

	for {
		cli, err := clientv3.New(clientv3.Config{
			Endpoints:   []string{endpoint},
			DialTimeout: 3 * time.Second,
		})
		if err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			_, err = cli.Status(ctx, endpoint)
			cancel()
			if err == nil {
				log.Printf("[INFO] etcd is ready!")
				return cli
			}
			cli.Close()
		}
		time.Sleep(time.Second)
	}
}

func watchLoop(cli *clientv3.Client, startRev int64) {
	rev := startRev

	for {
		ctx := context.Background()
		rch := cli.Watch(
			ctx,
			servicePrefix,
			clientv3.WithPrefix(),
			clientv3.WithRev(rev),
		)

		for wresp := range rch {
			if wresp.Err() != nil {
				log.Printf("[WARN] watch error: %v", wresp.Err())
				break
			}

			for _, ev := range wresp.Events {
				switch ev.Type {
				case mvccpb.PUT:
					log.Printf(
						"[INFO] Backend added/updated: %s -> %s",
						string(ev.Kv.Key),
						string(ev.Kv.Value),
					)
				case mvccpb.DELETE:
					log.Printf(
						"[INFO] Backend removed: %s",
						string(ev.Kv.Key),
					)
				}
			}

			rev = wresp.Header.Revision + 1
			reconcile(cli)
		}

		log.Printf("[WARN] watch closed, restarting from revision %d", rev)
		time.Sleep(time.Second)
	}
}

func reconcile(cli *clientv3.Client) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	resp, err := cli.Get(ctx, servicePrefix, clientv3.WithPrefix())
	if err != nil {
		log.Printf("[ERROR] reconcile get failed: %v", err)
		return
	}

	// CHANGE #1 applies here as well
	if len(resp.Kvs) == 0 {
		log.Printf("[INFO] No backends present, skipping HAProxy reload")
		return
	}

	renderAndReload(resp.Kvs)
}

func renderAndReload(kvs []*mvccpb.KeyValue) {
	log.Printf("[INFO] Rendering HAProxy config...")
	log.Printf("[INFO] Backends: %d", len(kvs))

	type backend struct {
		name string
		addr string
	}

	var backends []backend

	for _, kv := range kvs {
		key := string(kv.Key)
		val := string(kv.Value)
		name := filepath.Base(key)

		log.Printf("[DEBUG] Backend: %s -> %s", key, val)

		backends = append(backends, backend{
			name: name,
			addr: val,
		})
	}

	sort.Slice(backends, func(i, j int) bool {
		return backends[i].name < backends[j].name
	})

	singleBackend := len(backends) == 1

	var b strings.Builder

	b.WriteString(`global
    log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode http
    timeout connect 5s
    timeout client 50s
    timeout server 50s

frontend http-in
    bind *:80
    default_backend app

backend app
    balance roundrobin
`)

	// CHANGE #2: only enable health checks when more than one backend exists
	if !singleBackend {
		b.WriteString("    option httpchk GET /\n")
		b.WriteString("    default-server inter 2s rise 2 fall 3\n")
	}

	for _, be := range backends {
		if singleBackend {
			b.WriteString(fmt.Sprintf(
				"    server %s %s\n",
				be.name,
				be.addr,
			))
		} else {
			b.WriteString(fmt.Sprintf(
				"    server %s %s check\n",
				be.name,
				be.addr,
			))
		}
	}

	b.WriteString(`
listen stats
    bind *:8404
    stats enable
    stats uri /
`)

	if err := os.WriteFile(tmpCfg, []byte(b.String()), 0644); err != nil {
		log.Printf("[ERROR] write cfg failed: %v", err)
		return
	}

	cmd := exec.Command("haproxy", "-c", "-f", tmpCfg)
	if err := cmd.Run(); err != nil {
		log.Printf("[ERROR] haproxy config invalid: %v", err)
		return
	}

	if err := os.Rename(tmpCfg, haproxyCfg); err != nil {
		log.Printf("[ERROR] rename cfg failed: %v", err)
		return
	}

	log.Printf("[INFO] HAProxy config updated")
	startHAProxy()
}

func startHAProxy() {
	log.Printf("[INFO] Starting HAProxy...")

	cmd := exec.Command("haproxy", "-f", haproxyCfg, "-db")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		log.Fatalf("haproxy failed to start: %v", err)
	}
}
