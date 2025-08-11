#!/usr/bin/env python3
"""Test VoiceInk API endpoints"""

import requests
import json
import time
import sys

API_URL = "http://localhost:5000"

def test_health():
    """Test health check endpoint"""
    print("=" * 50)
    print("Testing Health Check Endpoint")
    print("=" * 50)
    
    try:
        response = requests.get(f"{API_URL}/health", timeout=5)
        if response.status_code == 200:
            data = response.json()
            print("✅ Health check successful!")
            print(f"Status: {data['status']}")
            print(f"Service: {data['service']}")
            print(f"Version: {data['version']}")
            print(f"Current Model: {data['transcription']['currentModel']}")
            print(f"Model Loaded: {data['transcription']['modelLoaded']}")
            print(f"API Running: {data['api']['isRunning']}")
            print(f"Requests Served: {data['api']['requestsServed']}")
            return True
        else:
            print(f"❌ Health check failed with status: {response.status_code}")
            return False
    except requests.exceptions.Timeout:
        print("❌ Health check timed out")
        return False
    except Exception as e:
        print(f"❌ Health check error: {e}")
        return False

def test_basic_transcription():
    """Test basic transcription without diarization"""
    print("\n" + "=" * 50)
    print("Testing Basic Transcription")
    print("=" * 50)
    
    try:
        with open('test_audio.wav', 'rb') as f:
            files = {'file': f}
            print("📤 Sending audio file for transcription...")
            
            response = requests.post(
                f"{API_URL}/api/transcribe",
                files=files,
                timeout=60
            )
            
            if response.status_code == 200:
                data = response.json()
                if data.get('success'):
                    print("✅ Transcription successful!")
                    print(f"Text: {data.get('text', 'No text returned')}")
                    if 'metadata' in data:
                        print(f"Model: {data['metadata'].get('model', 'Unknown')}")
                        print(f"Processing Time: {data['metadata'].get('processingTime', 0):.2f}s")
                        print(f"Audio Duration: {data['metadata'].get('duration', 0):.2f}s")
                    return True
                else:
                    print(f"❌ Transcription failed: {data.get('error', 'Unknown error')}")
                    return False
            else:
                print(f"❌ Request failed with status: {response.status_code}")
                print(f"Response: {response.text}")
                return False
                
    except requests.exceptions.Timeout:
        print("❌ Transcription request timed out (60s)")
        return False
    except FileNotFoundError:
        print("❌ test_audio.wav not found")
        return False
    except Exception as e:
        print(f"❌ Transcription error: {e}")
        return False

def test_diarization():
    """Test transcription with speaker diarization"""
    print("\n" + "=" * 50)
    print("Testing Transcription with Diarization")
    print("=" * 50)
    
    try:
        with open('conversation.wav', 'rb') as f:
            files = {'file': f}
            data = {
                'enable_diarization': 'true',
                'diarization_mode': 'balanced',
                'min_speakers': '2',
                'max_speakers': '4'
            }
            
            print("📤 Sending conversation audio with diarization enabled...")
            print(f"Parameters: {data}")
            
            response = requests.post(
                f"{API_URL}/api/transcribe",
                files=files,
                data=data,
                timeout=120
            )
            
            if response.status_code == 200:
                result = response.json()
                if result.get('success'):
                    print("✅ Diarization transcription successful!")
                    print(f"Text: {result.get('text', 'No text')[:200]}...")
                    
                    if 'speakers' in result:
                        print(f"\n👥 Speakers detected: {result['numSpeakers']}")
                        print(f"Speakers: {', '.join(result['speakers'])}")
                    
                    if 'segments' in result and result['segments']:
                        print("\n📝 First few segments:")
                        for seg in result['segments'][:3]:
                            print(f"  [{seg['speaker']}] ({seg['start']:.1f}s-{seg['end']:.1f}s): {seg['text']}")
                    
                    if 'textWithSpeakers' in result:
                        print("\n📄 Formatted text preview:")
                        preview = result['textWithSpeakers'][:300]
                        print(preview + "..." if len(result['textWithSpeakers']) > 300 else preview)
                    
                    if 'metadata' in result:
                        meta = result['metadata']
                        print(f"\n⏱️ Performance:")
                        print(f"  Total Time: {meta.get('processingTime', 0):.2f}s")
                        print(f"  Transcription: {meta.get('transcriptionTime', 0):.2f}s")
                        if 'diarizationTime' in meta:
                            print(f"  Diarization: {meta['diarizationTime']:.2f}s")
                        print(f"  Diarization Method: {meta.get('diarizationMethod', 'Unknown')}")
                    
                    return True
                else:
                    print(f"❌ Diarization failed: {result.get('error', 'Unknown error')}")
                    return False
            else:
                print(f"❌ Request failed with status: {response.status_code}")
                print(f"Response: {response.text[:500]}")
                return False
                
    except requests.exceptions.Timeout:
        print("❌ Diarization request timed out (120s)")
        return False
    except FileNotFoundError:
        print("❌ conversation.wav not found")
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
        response = requests.get(f"{API_URL}/health", timeout=5)
        if response.status_code == 200:
            data = response.json()
            current_model = data['transcription'].get('currentModel', '')
            if 'TDRZ' not in current_model:
                print(f"⚠️ Current model ({current_model}) doesn't support tinydiarize")
                print("  Please load a TDRZ model to test this feature")
                return False
    except:
        pass
    
    try:
        with open('conversation.wav', 'rb') as f:
            files = {'file': f}
            data = {
                'enable_diarization': 'true',
                'use_tinydiarize': 'true',
                'min_speakers': '2'
            }
            
            print("📤 Testing tinydiarize with conversation audio...")
            print(f"Parameters: {data}")
            
            response = requests.post(
                f"{API_URL}/api/transcribe",
                files=files,
                data=data,
                timeout=120
            )
            
            if response.status_code == 200:
                result = response.json()
                if result.get('success'):
                    print("✅ Tinydiarize transcription successful!")
                    
                    if 'metadata' in result:
                        print(f"Diarization Method: {result['metadata'].get('diarizationMethod', 'Unknown')}")
                    
                    if result['metadata'].get('diarizationMethod') == 'tinydiarize':
                        print("✅ Successfully used tinydiarize for speaker turns!")
                    
                    return True
                else:
                    print(f"❌ Tinydiarize failed: {result.get('error', 'Unknown error')}")
                    return False
            else:
                print(f"❌ Request failed with status: {response.status_code}")
                return False
                
    except Exception as e:
        print(f"❌ Tinydiarize error: {e}")
        return False

def main():
    """Run all tests"""
    print("\n🧪 VoiceInk API Test Suite")
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
    
    return 0 if passed == total else 1

if __name__ == "__main__":
    sys.exit(main())