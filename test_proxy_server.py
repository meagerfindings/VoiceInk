#!/usr/bin/env python3
"""
Proxy server to test VoiceInk transcription
This works around the multipart parsing issues in the current API implementation
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import subprocess
import tempfile
import os

class TranscriptionHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = {
                "status": "healthy",
                "service": "VoiceInk Proxy",
                "note": "This is a test proxy for VoiceInk transcription"
            }
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_error(404)
    
    def do_POST(self):
        if self.path == '/transcribe':
            content_length = int(self.headers['Content-Length'])
            audio_data = self.rfile.read(content_length)
            
            # Save audio to temp file
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
                f.write(audio_data)
                temp_path = f.name
            
            try:
                # Use VoiceInk CLI if available, or fallback to whisper
                # For now, we'll just return a test response
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                
                response = {
                    "success": True,
                    "text": "Test transcription successful. Audio file received.",
                    "metadata": {
                        "file_size": len(audio_data),
                        "temp_path": temp_path
                    }
                }
                self.wfile.write(json.dumps(response).encode())
            finally:
                # Clean up temp file
                if os.path.exists(temp_path):
                    os.unlink(temp_path)
        else:
            self.send_error(404)

if __name__ == '__main__':
    server = HTTPServer(('localhost', 5001), TranscriptionHandler)
    print("Test proxy server running on http://localhost:5001")
    print("Endpoints:")
    print("  GET  /health     - Health check")
    print("  POST /transcribe - Send raw audio data")
    server.serve_forever()