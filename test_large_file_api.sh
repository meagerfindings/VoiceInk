#!/bin/bash

echo "Testing VoiceInk API Large File Support"
echo "========================================"

# Create a large test file (20MB)
echo "Creating 20MB test file..."
dd if=/dev/zero of=test_large.mp3 bs=1024 count=20480 2>/dev/null
echo "Created test_large.mp3 (20MB)"

# Test health endpoint
echo ""
echo "1. Testing health endpoint..."
curl -v http://localhost:5000/health 2>&1 | head -20

# Test large file upload
echo ""
echo "2. Testing large file upload (20MB)..."
curl -X POST http://localhost:5000/api/transcribe \
  -F "file=@test_large.mp3" \
  --max-time 60 \
  -v 2>&1 | head -30

echo ""
echo "Test complete"