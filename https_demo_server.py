#!/usr/bin/env python3
"""
HTTPS Demo Server for WebSocket Demo
Serves static files over HTTPS to avoid mixed content security issues
"""

import http.server
import ssl
import socketserver
import os
import sys

class HTTPSHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.getcwd(), **kwargs)

def main():
    port = 8080
    cert_file = "/opt/riva/certs/server.crt"
    key_file = "/opt/riva/certs/server.key"

    # Check if certificates exist
    if not os.path.exists(cert_file) or not os.path.exists(key_file):
        print(f"❌ SSL certificates not found:")
        print(f"   Certificate: {cert_file}")
        print(f"   Key: {key_file}")
        sys.exit(1)

    # Create HTTPS server
    with socketserver.TCPServer(("0.0.0.0", port), HTTPSHandler) as httpd:
        # Setup SSL context
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(cert_file, key_file)
        httpd.socket = ssl_context.wrap_socket(httpd.socket, server_side=True)

        print(f"🔒 HTTPS Demo Server starting on port {port}")
        print(f"📋 Certificate: {cert_file}")
        print(f"🌐 Demo URL: https://3.16.124.227:{port}/static/demo.html")
        print(f"🔗 WebSocket: wss://3.16.124.227:8443/")
        print(f"📄 Access demo at: https://3.16.124.227:{port}/static/demo.html")
        print("   (Accept the self-signed certificate warning in your browser)")

        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n👋 HTTPS server stopped")

if __name__ == "__main__":
    main()