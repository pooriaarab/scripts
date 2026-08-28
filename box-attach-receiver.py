#!/usr/bin/env python3
"""Attach receiver. Runs inside an ascii.dev Box, exposed with `box host`.

Why this exists: every transport the box CLI offers pays an SSH handshake.
Measured round trips on a running Box: `box exec` 1.2s but it silently drops a
large argument, `box ssh` 5.2s, `box scp` 6.1s. An HTTPS POST to a hosted port
lands a 1.1MB tree in ~1.9s, extract and install decision included.

POST the gzipped tar of the worktree. Headers:
  X-Repo        repo directory name under /home/user/work
  X-Lock-Hash   hash of the lockfiles; install runs only when it changes
"""
import http.server, subprocess, os, pathlib

ROOT = "/home/user/work"

class H(http.server.BaseHTTPRequestHandler):
    # Stay on HTTP/1.0 semantics and close every connection. With HTTP/1.1
    # keep-alive on a single-threaded server, one idle connection blocks the
    # next request until it times out -- that turned a 1.7s attach into 90s.
    protocol_version = "HTTP/1.0"

    def do_POST(self):
        repo = self.headers.get("X-Repo", "repo")
        lock = self.headers.get("X-Lock-Hash", "")
        dest = os.path.join(ROOT, os.path.basename(repo))
        os.makedirs(dest, exist_ok=True)
        n = int(self.headers.get("Content-Length", 0))

        tar = subprocess.Popen(
            ["tar", "-xzf", "-", "--warning=no-unknown-keyword", "-C", dest],
            stdin=subprocess.PIPE)
        left = n
        while left > 0:
            chunk = self.rfile.read(min(65536, left))
            if not chunk:
                break
            tar.stdin.write(chunk)
            left -= len(chunk)
        tar.stdin.close()
        rc = tar.wait()

        # Installing is the slow part, so only do it when the lockfile moved.
        marker = pathlib.Path(dest, ".box-lock-hash")
        prev = marker.read_text().strip() if marker.exists() else ""
        installed = False
        if rc == 0 and lock and lock != prev:
            subprocess.run("bun install --frozen-lockfile || bun install",
                           shell=True, cwd=dest, capture_output=True)
            marker.write_text(lock)
            installed = True

        body = f"ok bytes={n} extract_rc={rc} installed={installed} dest={dest}\n".encode()
        self.send_response(200 if rc == 0 else 500)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("0.0.0.0", 8077), H).serve_forever()
