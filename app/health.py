import os
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

# This minimal app returns the required JSON response.
# In a real scenario, we might use Flask/FastAPI, but for 
# a single endpoint, standard library is dependency-free.

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            
            # Simulated commit and region (would be injected via CI/Ansible)
            response = {
                "service": "rewards",
                "status": "ok",
                "commit": os.getenv("COMMIT_SHA", "unknown"),
                "region": os.getenv("AWS_REGION", "us-east-1"),
                "secret_present": os.getenv("APP_SECRET") is not None
            }
            self.wfile.write(json.dumps(response).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    port = int(os.getenv("APP_PORT", 8080))
    server = HTTPServer(('0.0.0.0', port), HealthHandler)
    print(f"Starting server on port {port}...")
    server.serve_forever()
