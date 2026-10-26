"""Serves tests/fixtures/webshot/audit on 127.0.0.1 with one redirect.

/redirect answers 302 to /wide.html. Prints the port on stdout, then serves
until killed. Used by tests/webshot_test.sh.
"""
import http.server
import os
import sys

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "audit"))


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/wide.html")
            self.end_headers()
            return
        super().do_GET()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
sys.stdout.close()
server.serve_forever()
