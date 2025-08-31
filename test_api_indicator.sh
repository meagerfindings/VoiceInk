#!/bin/bash

# Test script for API Processing Indicator
# This script sends a test request to the API server to trigger the indicator

echo "🧪 Testing API Processing Indicator"
echo "=================================="

# Check if VoiceInk app is running (assuming API server is on default port 5000)
if ! lsof -i :5000 > /dev/null 2>&1; then
    echo "❌ API server is not running on port 5000"
    echo "Please start VoiceInk and enable the API server first"
    exit 1
fi

echo "✅ API server is running on port 5000"

# Test with a simple health check first
echo "📡 Testing health endpoint..."
curl -s http://localhost:5000/health > /dev/null
if [ $? -eq 0 ]; then
    echo "✅ Health endpoint is responding"
else
    echo "❌ Health endpoint is not responding"
    exit 1
fi

# Create a small test audio file (empty wav file)
echo "🎵 Creating test audio file..."
cat > /tmp/test_audio.wav << 'EOF'
UklGRigAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA=
EOF

# Decode base64 test audio
echo "UklGRigAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA=" | base64 -d > /tmp/test_audio.wav

echo "📤 Sending test transcription request..."
echo "This should trigger the API processing indicator in the dashboard!"
echo ""
echo "👀 Check the VoiceInk dashboard now - you should see the processing indicator appear."
echo ""

# Send the test request (this will trigger the processing indicator)
curl -X POST \
  -H "Content-Type: multipart/form-data" \
  -F "file=@/tmp/test_audio.wav" \
  http://localhost:5000/transcribe

echo ""
echo ""
echo "✅ Test request sent! The processing indicator should have appeared and then disappeared."
echo "🧹 Cleaning up test files..."
rm -f /tmp/test_audio.wav

echo "🎉 Test completed!"