#!/usr/bin/env python3
"""Comprehensive VoiceInk API test using standard library"""

import urllib.request
import urllib.parse
import json
import time
import os

API_URL = "http://localhost:5000"

def test_health():
    """Test health check endpoint"""
    print("=" * 50)
    print("Testing Health Check Endpoint")
    print("=" * 50)
    try:
        with urllib.request.urlopen(f"{API_URL}/health", timeout=5) as response:
            data = json.loads(response.read().decode())
            print(f"✅ Status: {data['status']}")
            print(f"   Service: {data['service']}")
            print(f"   Version: {data['version']}")
            print(f"   Current Model: {data['transcription']['currentModel']}")
            print(f"   Model Loaded: {data['transcription']['modelLoaded']}")
            print(f"   API Running: {data['api']['isRunning']}")
            print(f"   Requests Served: {data['api']['requestsServed']}")
            return True
    except Exception as e:
        print(f"❌ Health check failed: {e}")
        return False

def test_basic_transcription():
    """Test basic transcription"""
    print("\n" + "=" * 50)
    print("Testing Basic Transcription")
    print("=" * 50)
    
    if not os.path.exists('test_audio.wav'):
        print("❌ test_audio.wav not found")
        return False
    
    # Create multipart form data
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
        
        print("📤 Sending audio file for transcription...")
        start_time = time.time()
        
        with urllib.request.urlopen(req, timeout=60) as response:
            result = json.loads(response.read().decode())
            elapsed = time.time() - start_time
            
            if result.get('success'):
                print(f"✅ Transcription successful!")
                print(f"   Text: {result.get('text', 'No text')}")
                if 'metadata' in result:
                    print(f"   Model: {result['metadata'].get('model', 'Unknown')}")
                    print(f"   Processing Time: {result['metadata'].get('processingTime', elapsed):.2f}s")
                    print(f"   Audio Duration: {result['metadata'].get('duration', 0):.2f}s")
                return True
            else:
                print(f"❌ Failed: {result.get('error', 'Unknown error')}")
                return False
                
    except Exception as e:
        print(f"❌ Transcription error: {e}")
        return False

def test_diarization():
    """Test transcription with diarization"""
    print("\n" + "=" * 50)
    print("Testing Transcription with Diarization")
    print("=" * 50)
    
    if not os.path.exists('conversation.wav'):
        print("❌ conversation.wav not found")
        return False
    
    # Create multipart form data with diarization params
    boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'
    
    try:
        with open('conversation.wav', 'rb') as f:
            audio_data = f.read()
        
        # Build the multipart body with diarization parameters
        body = []
        
        # Add file
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="file"; filename="conversation.wav"')
        body.append(b'Content-Type: audio/wav')
        body.append(b'')
        body.append(audio_data)
        
        # Add diarization parameters
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="enable_diarization"')
        body.append(b'')
        body.append(b'true')
        
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="diarization_mode"')
        body.append(b'')
        body.append(b'balanced')
        
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="min_speakers"')
        body.append(b'')
        body.append(b'2')
        
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="max_speakers"')
        body.append(b'')
        body.append(b'4')
        
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
        
        print("📤 Sending conversation audio with diarization enabled...")
        print("   Parameters: enable_diarization=true, mode=balanced, min_speakers=2, max_speakers=4")
        start_time = time.time()
        
        with urllib.request.urlopen(req, timeout=120) as response:
            result = json.loads(response.read().decode())
            elapsed = time.time() - start_time
            
            if result.get('success'):
                print(f"✅ Diarization transcription successful!")
                print(f"   Processing time: {elapsed:.2f}s")
                
                # Display transcription preview
                text = result.get('text', '')
                if text:
                    preview = text[:200] + "..." if len(text) > 200 else text
                    print(f"   Text preview: {preview}")
                
                # Check for speaker information
                if 'speakers' in result:
                    print(f"\n👥 Speakers detected: {result.get('numSpeakers', 'Unknown')}")
                    print(f"   Speakers: {', '.join(result['speakers'])}")
                
                # Show first few segments if available
                if 'segments' in result and result['segments']:
                    print("\n📝 First few segments:")
                    for seg in result['segments'][:3]:
                        print(f"   [{seg['speaker']}] ({seg['start']:.1f}s-{seg['end']:.1f}s): {seg['text']}")
                
                # Show formatted text preview if available
                if 'textWithSpeakers' in result:
                    print("\n📄 Formatted text preview:")
                    preview = result['textWithSpeakers'][:300]
                    print("   " + preview + ("..." if len(result['textWithSpeakers']) > 300 else ""))
                
                # Show performance metrics
                if 'metadata' in result:
                    meta = result['metadata']
                    print(f"\n⏱️ Performance:")
                    print(f"   Total Time: {meta.get('processingTime', elapsed):.2f}s")
                    if 'transcriptionTime' in meta:
                        print(f"   Transcription: {meta['transcriptionTime']:.2f}s")
                    if 'diarizationTime' in meta:
                        print(f"   Diarization: {meta['diarizationTime']:.2f}s")
                    print(f"   Diarization Method: {meta.get('diarizationMethod', 'Unknown')}")
                
                return True
            else:
                print(f"❌ Diarization failed: {result.get('error', 'Unknown error')}")
                return False
                
    except Exception as e:
        print(f"❌ Diarization error: {e}")
        return False

def test_tinydiarize():
    """Test with tinydiarize if TDRZ model is loaded"""
    print("\n" + "=" * 50)
    print("Testing Tinydiarize (Speaker Turn Detection)")
    print("=" * 50)
    
    # First check if a TDRZ model is loaded
    try:
        with urllib.request.urlopen(f"{API_URL}/health", timeout=5) as response:
            data = json.loads(response.read().decode())
            current_model = data['transcription'].get('currentModel', '')
            if 'TDRZ' not in current_model.upper():
                print(f"⚠️  Current model ({current_model}) doesn't support tinydiarize")
                print("   Please load a TDRZ model (e.g., 'Small TDRZ (English)') to test this feature")
                return False
    except:
        pass
    
    if not os.path.exists('conversation.wav'):
        print("❌ conversation.wav not found")
        return False
    
    # Create multipart form data with tinydiarize
    boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'
    
    try:
        with open('conversation.wav', 'rb') as f:
            audio_data = f.read()
        
        # Build the multipart body
        body = []
        
        # Add file
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="file"; filename="conversation.wav"')
        body.append(b'Content-Type: audio/wav')
        body.append(b'')
        body.append(audio_data)
        
        # Add tinydiarize parameters
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="enable_diarization"')
        body.append(b'')
        body.append(b'true')
        
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="use_tinydiarize"')
        body.append(b'')
        body.append(b'true')
        
        body.append(f'--{boundary}'.encode())
        body.append(b'Content-Disposition: form-data; name="min_speakers"')
        body.append(b'')
        body.append(b'2')
        
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
        
        print("📤 Testing tinydiarize with conversation audio...")
        print("   Parameters: enable_diarization=true, use_tinydiarize=true, min_speakers=2")
        
        with urllib.request.urlopen(req, timeout=120) as response:
            result = json.loads(response.read().decode())
            
            if result.get('success'):
                print("✅ Tinydiarize transcription successful!")
                
                if 'metadata' in result:
                    method = result['metadata'].get('diarizationMethod', 'Unknown')
                    print(f"   Diarization Method: {method}")
                    if method == 'tinydiarize':
                        print("   ✅ Successfully used tinydiarize for speaker turns!")
                
                return True
            else:
                print(f"❌ Tinydiarize failed: {result.get('error', 'Unknown error')}")
                return False
                
    except Exception as e:
        print(f"❌ Tinydiarize error: {e}")
        return False

def main():
    """Run all tests"""
    print("\n🧪 VoiceInk API Comprehensive Test Suite")
    print("=" * 50)
    
    results = {
        "Health Check": test_health(),
        "Basic Transcription": test_basic_transcription(),
        "Diarization": test_diarization(),
        "Tinydiarize": test_tinydiarize()
    }
    
    print("\n" + "=" * 50)
    print("📊 Test Results Summary")
    print("=" * 50)
    
    for test_name, passed in results.items():
        status = "✅ PASSED" if passed else "❌ FAILED"
        print(f"{test_name}: {status}")
    
    total = len(results)
    passed = sum(1 for v in results.values() if v)
    print(f"\nTotal: {passed}/{total} tests passed")
    
    if passed == total:
        print("\n🎉 All tests passed successfully!")
    elif passed > 0:
        print(f"\n⚠️  {passed} out of {total} tests passed")
    else:
        print("\n❌ All tests failed")
    
    return 0 if passed == total else 1

if __name__ == "__main__":
    exit(main())