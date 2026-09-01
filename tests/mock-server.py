#!/usr/bin/env python3
"""
Minimal stand-in for the services the cron scripts talk to, used by
tests/scripts-smoke.sh (and runnable by hand for local debugging).

  POST /            -> Ethereum JSON-RPC (eth_blockNumber, eth_getBalance,
                       net_peerCount, eth_syncing, eth_chainId)
  PUT/POST/DELETE /metrics/job/...  -> Pushgateway; every request is recorded
  POST /webhook     -> generic webhook sink; every body is recorded

Usage: mock-server.py <port> <record-dir> [--geth-down]

Each recorded request is written to <record-dir>/<n>.<METHOD> as
"<path>\n\n<body>". stdlib only, so it runs anywhere CI has python3.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
RECORD_DIR = sys.argv[2]
GETH_DOWN = "--geth-down" in sys.argv[3:]
os.makedirs(RECORD_DIR, exist_ok=True)

# 10 ETH in wei = 0x8AC7230489E80000 -- deliberately above 2^63-1 so the
# smoke test catches any 64-bit overflow in hex->decimal conversion.
RPC_RESULTS = {
    "eth_blockNumber": "0x7a1200",
    "eth_getBalance": "0x8AC7230489E80000",
    "net_peerCount": "0x19",
    "eth_syncing": False,
    "eth_chainId": "0xaa36a7",
}


class Handler(BaseHTTPRequestHandler):
    counter = 0

    def log_message(self, *args):  # keep test output quiet
        pass

    def _record(self, body):
        Handler.counter += 1
        path = os.path.join(RECORD_DIR, f"{Handler.counter:03d}.{self.command}")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(self.path + "\n\n" + body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length).decode("utf-8", "replace") if length else ""

    def _reply(self, code=200, payload=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        body = self._body()
        if self.path.startswith("/metrics/") or self.path.startswith("/webhook"):
            self._record(body)
            return self._reply(200)
        if GETH_DOWN:
            return self._reply(503)
        try:
            req = json.loads(body)
            result = RPC_RESULTS[req["method"]]
        except (ValueError, KeyError):
            return self._reply(400)
        # geth emits compact JSON; keep the same shape
        payload = json.dumps({"jsonrpc": "2.0", "id": req.get("id", 1), "result": result},
                             separators=(",", ":"))
        return self._reply(200, payload.encode())

    def do_PUT(self):
        self._record(self._body())
        self._reply(200)

    def do_DELETE(self):
        self._record("")
        self._reply(202)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
