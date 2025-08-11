#!/bin/bash

# Test script for VoiceInk API

echo "Testing VoiceInk API..."
echo ""

# Test 1: Health check
echo "1. Testing health endpoint..."
HEALTH=$(curl -s http://localhost:5000/health)
if [ $? -eq 0 ]; then
    echo "✓ Health endpoint responded"
    echo "$HEALTH" | python3 -m json.tool | head -20
else
    echo "✗ Health endpoint failed"
fi
echo ""

# Test 2: Check if model is loaded
echo "2. Checking if model is loaded..."
MODEL_LOADED=$(echo "$HEALTH" | python3 -c "import sys, json; print(json.load(sys.stdin).get('transcription', {}).get('modelLoaded', False))" 2>/dev/null)
if [ "$MODEL_LOADED" = "True" ]; then
    echo "✓ Model is loaded"
else
    echo "✗ Model is not loaded"
    echo "  Please ensure a transcription model is selected in VoiceInk"
fi
echo ""

# Test 3: Transcription test (if you have a test audio file)
if [ -f "test_audio.wav" ]; then
    echo "3. Testing transcription endpoint..."
    RESPONSE=$(curl -s -X POST http://localhost:5000/api/transcribe -F "file=@test_audio.wav")
    if [ $? -eq 0 ]; then
        SUCCESS=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
        if [ "$SUCCESS" = "True" ]; then
            echo "✓ Transcription succeeded"
            echo "$RESPONSE" | python3 -m json.tool | head -30
        else
            echo "✗ Transcription failed"
            echo "$RESPONSE" | python3 -m json.tool
        fi
    else
        echo "✗ Transcription request failed"
    fi
else
    echo "3. Skipping transcription test (no test_audio.wav file found)"
    echo "   To test transcription, create a test_audio.wav file"
fi