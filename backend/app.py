import os
import socket
import time
import json
import requests
import threading
import base64

ETCD_ENDPOINTS = os.environ.get(
    "ETCD_ENDPOINTS",
    "http://etcd1:2379,http://etcd2:2379,http://etcd3:2379"
).split(",")

SERVICE_PORT = int(os.environ.get("SERVICE_PORT", "8080"))
LEASE_TTL = 10  # seconds

hostname = socket.gethostname()
ip = socket.gethostbyname(hostname)

KEY = f"/services/backend/{hostname}"
VALUE = f"{ip}:{SERVICE_PORT}"

def b64(s: str) -> str:
    return base64.b64encode(s.encode()).decode()

def etcd_post(path, payload):
    for ep in ETCD_ENDPOINTS:
        try:
            r = requests.post(f"{ep}{path}", json=payload, timeout=2)
            r.raise_for_status()
            return r.json()
        except Exception as e:
            last_err = e
    raise last_err

def create_lease():
    resp = etcd_post(
        "/v3/lease/grant",
        {"TTL": LEASE_TTL}
    )
    return resp["ID"]

def put_key(lease_id):
    etcd_post(
        "/v3/kv/put",
        {
            "key": b64(KEY),
            "value": b64(VALUE),
            "lease": lease_id
        }
    )

def keepalive_loop(lease_id):
    while True:
        try:
            etcd_post(
                "/v3/lease/keepalive",
                {"ID": lease_id}
            )
            time.sleep(LEASE_TTL / 2)
        except Exception as e:
            print(f"✗ Lease keepalive failed: {e}")
            os._exit(1)

def start_http_server():
    from http.server import HTTPServer, BaseHTTPRequestHandler

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(
                f"Hello from {hostname}\n".encode()
            )

    server = HTTPServer(("0.0.0.0", SERVICE_PORT), Handler)
    print(f"Backend listening on {SERVICE_PORT}")
    server.serve_forever()

if __name__ == "__main__":
    print("Backend Service Starting")
    print(f"Registering {KEY} -> {VALUE}")

    lease_id = create_lease()
    put_key(lease_id)

    print(f"Lease created (TTL={LEASE_TTL}s)")

    threading.Thread(
        target=keepalive_loop,
        args=(lease_id,),
        daemon=True
    ).start()

    start_http_server()

