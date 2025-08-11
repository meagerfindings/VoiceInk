#!/usr/bin/env python3
"""
Comprehensive API test script for VoiceInk
Tests all API endpoints with various scenarios
"""

import requests
import json
import os
import time
from pathlib import Path

# API configuration
API_URL = "http://localhost:7777"
HEALTH_ENDPOINT = f"{API_URL}/health"
TRANSCRIBE_ENDPOINT = f"{API_URL}/api/transcribe"

# Test audio files
TEST_FILES = [
    "test_short.wav",
    "conversation.wav",
    "speaker1.wav",
    "speaker2.wav"
]

def test_health():
    """Test the health endpoint"""
    print("\n" + "="*50)
    print("Testing Health Endpoint")
    print("="*50)
    
    try:
        response = requests.get(HEALTH_ENDPOINT, timeout=5)
        if response.status_code == 200:
            data = response.json()
            print(f"✅ Health check successful")
            print(f"Status: {data.get('status')}")
            print(f"API Enabled: {data.get('apiEnabled')}")
            print(f"Current Model: {data.get('currentModel')}")
            print(f"API Diarization Model: {data.get('apiDiarizationModel')}")
            print(f"Models Loaded: {data.get('modelsLoaded')}")
            return True
        else:
            print(f"❌ Health check failed with status {response.status_code}")
            return False
    except requests.exceptions.ConnectionError:
        print("❌ Cannot connect to API server at http://localhost:7777")
        print("   Please ensure VoiceInk is running and API server is enabled")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

def test_transcription(audio_file, enable_diarization=False, use_tinydiarize=False):
    """Test transcription endpoint"""
    print("\n" + "-"*50)
    print(f"Testing: {audio_file}")
    print(f"Diarization: {enable_diarization}, Tinydiarize: {use_tinydiarize}")
    print("-"*50)
    
    if not os.path.exists(audio_file):
        print(f"❌ File not found: {audio_file}")
        return False
    
    try:
        with open(audio_file, 'rb') as f:
            files = {'file': (audio_file, f, 'audio/wav')}
            
            # Add diarization parameters if requested
            data = {}
            if enable_diarization:
                data['enable_diarization'] = 'true'
                data['diarization_mode'] = 'quality'
                data['min_speakers'] = '1'
                data['max_speakers'] = '4'
                if use_tinydiarize:
                    data['use_tinydiarize'] = 'true'
            
            response = requests.post(
                TRANSCRIBE_ENDPOINT, 
                files=files,
                data=data,
                timeout=30
            )
            
            if response.status_code == 200:
                result = response.json()
                
                if result.get('success'):
                    print(f"✅ Transcription successful")
                    print(f"\nText: {result.get('text', '')[:200]}...")
                    
                    if result.get('enhancedText'):
                        print(f"\nEnhanced: {result.get('enhancedText', '')[:200]}...")
                    
                    metadata = result.get('metadata', {})
                    print(f"\nMetadata:")
                    print(f"  Model: {metadata.get('model')}")
                    print(f"  Duration: {metadata.get('duration', 0):.2f}s")
                    print(f"  Processing: {metadata.get('processingTime', 0):.2f}s")
                    
                    if enable_diarization and 'segments' in result:
                        print(f"\nDiarization Results:")
                        print(f"  Speakers: {result.get('numSpeakers', 0)}")
                        print(f"  Method: {metadata.get('diarizationMethod', 'N/A')}")
                        
                        # Show first few segments
                        segments = result.get('segments', [])[:3]
                        for seg in segments:
                            print(f"  [{seg['start']:.1f}-{seg['end']:.1f}] {seg['speaker']}: {seg['text'][:50]}...")
                    
                    return True
                else:
                    print(f"❌ Transcription failed: {result.get('error', 'Unknown error')}")
                    return False
            else:
                print(f"❌ Request failed with status {response.status_code}")
                print(f"   Response: {response.text[:500]}")
                return False
                
    except requests.exceptions.Timeout:
        print("❌ Request timed out (30s)")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

def main():
    """Run all API tests"""
    print("\n" + "="*60)
    print(" VoiceInk API Test Suite")
    print("="*60)
    
    # Test health endpoint
    if not test_health():
        print("\n⚠️  API server is not accessible. Please:")
        print("1. Ensure VoiceInk is running")
        print("2. Enable API server in Settings > API")
        print("3. Check that port 7777 is not in use")
        return
    
    print("\n" + "="*50)
    print("Testing Transcription Endpoints")
    print("="*50)
    
    # Test basic transcription
    for audio_file in TEST_FILES:
        if os.path.exists(audio_file):
            # Basic transcription
            test_transcription(audio_file, enable_diarization=False)
            
            # Test with diarization if it's a conversation file
            if "conversation" in audio_file or "speaker" in audio_file:
                test_transcription(audio_file, enable_diarization=True, use_tinydiarize=False)
                
                # Test with tinydiarize if available
                # test_transcription(audio_file, enable_diarization=True, use_tinydiarize=True)
            
            time.sleep(1)  # Brief pause between tests
    
    print("\n" + "="*60)
    print(" Test Suite Complete")
    print("="*60)

if __name__ == "__main__":
    main()