#!/usr/bin/env python3
"""
Simple HTTP proxy to forward LM Studio requests from localhost:1234 to 192.168.101.21:1234
"""

import http.server
import socketserver
import urllib.request
import urllib.parse
import json
import sys

TARGET_HOST = "192.168.101.21"
TARGET_PORT = 1234

class LMStudioProxy(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/v1"):
            target_url = f"http://{TARGET_HOST}:{TARGET_PORT}{self.path}"
            print(f"Proxying GET {self.path} -> {target_url}")
            
            try:
                req = urllib.request.Request(target_url)
                with urllib.request.urlopen(req, timeout=30) as response:
                    self.send_response(response.status)
                    for header, value in response.headers.items():
                        if header.lower() not in ['transfer-encoding', 'connection', 'keep-alive']:
                            self.send_header(header, value)
                    self.end_headers()
                    
                    # Read and send response
                    data = response.read()
                    self.wfile.write(data)
                    
                    # Log models if this is the models endpoint
                    if "/v1/models" in self.path:
                        try:
                            models_data = json.loads(data.decode('utf-8'))
                            models = [m['id'] for m in models_data.get('data', [])]
                            print(f"Models available: {models}")
                        except:
                            pass
                            
            except Exception as e:
                print(f"Error proxying request: {e}")
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"Proxy error: {e}".encode())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found")
    
    def do_POST(self):
        if self.path.startswith("/v1"):
            target_url = f"http://{TARGET_HOST}:{TARGET_PORT}{self.path}"
            print(f"Proxying POST {self.path} -> {target_url}")
            
            # Read request body
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length) if content_length else b''
            
            try:
                req = urllib.request.Request(target_url, data=body, method='POST')
                # Copy headers
                for header, value in self.headers.items():
                    if header.lower() not in ['host', 'content-length']:
                        req.add_header(header, value)
                
                with urllib.request.urlopen(req, timeout=30) as response:
                    self.send_response(response.status)
                    for header, value in response.headers.items():
                        if header.lower() not in ['transfer-encoding', 'connection', 'keep-alive']:
                            self.send_header(header, value)
                    self.end_headers()
                    
                    # Read and send response
                    data = response.read()
                    self.wfile.write(data)
                    
            except Exception as e:
                print(f"Error proxying POST request: {e}")
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"Proxy error: {e}".encode())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found")

def run_proxy(port=1234):
    with socketserver.TCPServer(("", port), LMStudioProxy) as httpd:
        print(f"LM Studio proxy running on port {port}")
        print(f"Forwarding to {TARGET_HOST}:{TARGET_PORT}")
        print(f"OpenCode can now use http://localhost:{port}/v1")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down proxy...")
            httpd.shutdown()

if __name__ == "__main__":
    run_proxy()