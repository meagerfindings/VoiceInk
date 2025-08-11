#!/bin/bash

# Test script for VoiceInk API with MP3 files

echo "Testing VoiceInk API with MP3 files..."
echo ""

PORT=${1:-5000}
BASE_URL="http://localhost:$PORT"

# Function to create a test MP3 file using macOS's say command
create_test_mp3() {
    echo "Creating test MP3 file..."
    say -o test_audio.aiff "Hello, this is a test of the VoiceInk API with MP3 files"
    ffmpeg -i test_audio.aiff -acodec mp3 -ab 128k test_audio.mp3 2>/dev/null
    rm test_audio.aiff
    echo "✓ Created test_audio.mp3"
}

# Function to test transcription
test_transcription() {
    local file=$1
    local format=$2
    
    echo "Testing with $format file: $file"
    
    if [ ! -f "$file" ]; then
        echo "  ✗ File not found: $file"
        return
    fi
    
    # Get file info
    echo "  File info:"
    file "$file" | sed 's/^/    /'
    ls -lh "$file" | awk '{print "    Size: " $5}'
    
    # Send transcription request
    echo "  Sending transcription request..."
    RESPONSE=$(curl -s -X POST "$BASE_URL/api/transcribe" \
        -F "file=@$file" \
        -w "\nHTTP_STATUS:%{http_code}")
    
    HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
    JSON_RESPONSE=$(echo "$RESPONSE" | sed '/HTTP_STATUS:/d')
    
    if [ "$HTTP_STATUS" = "200" ]; then
        SUCCESS=$(echo "$JSON_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
        if [ "$SUCCESS" = "True" ]; then
            echo "  ✓ Transcription succeeded!"
            echo "  Response preview:"
            echo "$JSON_RESPONSE" | python3 -m json.tool | head -20 | sed 's/^/    /'
        else
            echo "  ✗ Transcription failed (success=false)"
            echo "  Error:"
            echo "$JSON_RESPONSE" | python3 -m json.tool | sed 's/^/    /'
        fi
    else
        echo "  ✗ HTTP Error: $HTTP_STATUS"
        echo "  Response:"
        echo "$JSON_RESPONSE" | sed 's/^/    /'
    fi
    echo ""
}

# Check if ffmpeg is available for MP3 creation
if ! command -v ffmpeg &> /dev/null; then
    echo "Warning: ffmpeg not found. Install with: brew install ffmpeg"
    echo "Skipping MP3 creation test."
    echo ""
fi

# Create test MP3 if ffmpeg is available and file doesn't exist
if command -v ffmpeg &> /dev/null && [ ! -f "test_audio.mp3" ]; then
    create_test_mp3
fi

# Test with different audio files
echo "=== Testing Audio Format Support ==="
echo ""

# Test MP3 if available
if [ -f "test_audio.mp3" ]; then
    test_transcription "test_audio.mp3" "MP3"
fi

# Test WAV if available  
if [ -f "test_audio.wav" ]; then
    test_transcription "test_audio.wav" "WAV"
fi

# Test M4A if available
if [ -f "test_audio.m4a" ]; then
    test_transcription "test_audio.m4a" "M4A"
fi

# Test with a podcast MP3 if provided
if [ -n "$2" ]; then
    echo "Testing with provided file: $2"
    test_transcription "$2" "Provided"
fi

echo "=== Test Complete ==="
echo ""
echo "Usage:"
echo "  $0 [port] [audio_file]"
echo ""
echo "Examples:"
echo "  $0                    # Use default port 5000"
echo "  $0 5000               # Use custom port"
echo "  $0 5000 podcast.mp3   # Test with specific file"