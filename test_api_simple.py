#!/usr/bin/env python3
"""Simple VoiceInk API test using only standard library"""

import urllib.request
import urllib.parse
import json
import time

API_URL = "http://localhost:5000"

def test_health():
    """Test health check endpoint"""
    print("Testing Health Check...")
    try:
        with urllib.request.urlopen(f"{API_URL}/health", timeout=5) as response:
            data = json.loads(response.read().decode())
            print(f"✅ Status: {data['status']}")
            print(f"   Model: {data['transcription']['currentModel']}")
            print(f"   Loaded: {data['transcription']['modelLoaded']}")
            return True
    except Exception as e:
        print(f"❌ Health check failed: {e}")
        return False

def test_transcription():
    """Test basic transcription"""
    print("\nTesting Basic Transcription...")
    
    # Create multipart form data manually
    boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'
    
    try:
        with open('test_audio.wav', 'rb') as f:
            audio_data = f.read()
        
        # Build the multipart body
        body = []
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="file"; filename="test.wav"')
        body.append(b'Content-Type: audio/wav')
        body.append(b'')
        body.append(audio_data)
        body.append(f'--{boundary}--'.encode())
        
        body_bytes = b'\r\n'.join(body)
        
        # Create request
        req = urllib.request.Request(
            f"{API_URL}/api/transcribe",
            data=body_bytes,
            headers={
                'Content-Type': f'multipart/form-data; boundary={boundary}',
                'Content-Length': str(len(body_bytes))
            }
        )
        
        print("   Sending request (this may take a moment)...")
        with urllib.request.urlopen(req, timeout=60) as response:
            result = json.loads(response.read().decode())
            if result.get('success'):
                print(f"✅ Transcription: {result.get('text', 'No text')}")
                return True
            else:
                print(f"❌ Failed: {result.get('error', 'Unknown error')}")
                return False
                
    except Exception as e:
        print(f"❌ Transcription error: {e}")
        return False

# Run tests
print("🧪 VoiceInk API Quick Test\n")
health_ok = test_health()
trans_ok = test_transcription() if health_ok else False

print(f"\n📊 Results: Health={'✅' if health_ok else '❌'}, Transcription={'✅' if trans_ok else '❌'}")