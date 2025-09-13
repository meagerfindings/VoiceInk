#!/bin/bash

# Test script to verify the enhanced API banner displays filename

echo "Testing API with filename display enhancement..."
echo "Starting VoiceInk API server for testing..."

# Create a small test audio file (1 second of silence)
echo "Creating test audio file..."
ffmpeg -f lavfi -i anullsrc=r=22050:cl=mono -t 1 -acodec pcm_s16le test_audio.wav -y >/dev/null 2>&1

# Check if audio file was created
if [ ! -f "test_audio.wav" ]; then
    echo "❌ Failed to create test audio file"
    exit 1
fi

echo "✅ Test audio file created ($(du -h test_audio.wav | cut -f1))"

# Wait for API server to be ready
echo "Waiting for API server to start..."
timeout=10
counter=0
while [ $counter -lt $timeout ]; do
    if curl -s http://localhost:5000/health >/dev/null 2>&1; then
        echo "✅ API server is ready"
        break
    fi
    sleep 1
    counter=$((counter + 1))
done

if [ $counter -eq $timeout ]; then
    echo "❌ API server not ready after ${timeout} seconds"
    exit 1
fi

# Test the API with the filename
echo "📤 Sending test audio file to API..."
echo "   This should display: 'Processing test_audio.wav (0.0 MB)' in the banner"

response=$(curl -s -X POST \
  -F "file=@test_audio.wav" \
  http://localhost:5000/api/transcribe)

echo "📥 API Response: $response"

# Cleanup
rm -f test_audio.wav

echo "✅ Test completed!"
echo ""
echo "To verify the enhancement worked:"
echo "1. Check the VoiceInk app's Metrics/Dashboard view"
echo "2. You should have seen a banner showing 'Processing test_audio.wav (0.0 MB)'"
echo "3. Instead of just 'Processing 0.0 MB audio file...'"