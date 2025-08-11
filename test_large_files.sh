#!/bin/bash

# Test script for VoiceInk API with large audio files

echo "VoiceInk API Large File Test"
echo "============================"
echo ""

PORT=${1:-5000}
BASE_URL="http://localhost:$PORT"

# Function to test large file upload with monitoring
test_large_file() {
    local file=$1
    local description=$2
    
    if [ ! -f "$file" ]; then
        echo "❌ File not found: $file"
        return 1
    fi
    
    # Get file size
    SIZE=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    SIZE_MB=$((SIZE / 1024 / 1024))
    
    echo "Testing: $description"
    echo "  File: $file"
    echo "  Size: ${SIZE_MB}MB (${SIZE} bytes)"
    echo ""
    
    # Start timing
    START_TIME=$(date +%s)
    
    echo "  Uploading to VoiceInk API..."
    
    # Upload with progress monitoring using curl
    RESPONSE=$(curl -X POST "$BASE_URL/api/transcribe" \
        -F "file=@$file" \
        --progress-bar \
        --max-time 600 \
        --connect-timeout 30 \
        -w "\n---\nHTTP_CODE:%{http_code}\nTIME_TOTAL:%{time_total}\nSIZE_UPLOAD:%{size_upload}\n" \
        -o /tmp/voiceink_response.json \
        2>&1)
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    # Extract metrics
    HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
    TIME_TOTAL=$(echo "$RESPONSE" | grep "TIME_TOTAL:" | cut -d: -f2)
    SIZE_UPLOAD=$(echo "$RESPONSE" | grep "SIZE_UPLOAD:" | cut -d: -f2)
    
    echo ""
    echo "  Results:"
    echo "    HTTP Status: $HTTP_CODE"
    echo "    Duration: ${DURATION} seconds"
    echo "    Upload Size: $((SIZE_UPLOAD / 1024 / 1024))MB"
    
    if [ "$HTTP_CODE" = "200" ]; then
        # Check response
        if [ -f /tmp/voiceink_response.json ]; then
            SUCCESS=$(python3 -c "import json; data=json.load(open('/tmp/voiceink_response.json')); print(data.get('success', False))" 2>/dev/null)
            
            if [ "$SUCCESS" = "True" ]; then
                echo "    ✅ Transcription successful!"
                
                # Show text preview
                TEXT_LENGTH=$(python3 -c "import json; data=json.load(open('/tmp/voiceink_response.json')); print(len(data.get('text', '')))" 2>/dev/null)
                echo "    Text length: $TEXT_LENGTH characters"
                
                # Show first 200 chars of transcription
                echo ""
                echo "    Preview:"
                python3 -c "import json; data=json.load(open('/tmp/voiceink_response.json')); print(data.get('text', '')[:200] + '...')" 2>/dev/null | sed 's/^/      /'
            else
                echo "    ❌ Transcription failed"
                ERROR=$(python3 -c "import json; data=json.load(open('/tmp/voiceink_response.json')); print(data.get('error', {}).get('message', 'Unknown error'))" 2>/dev/null)
                echo "    Error: $ERROR"
            fi
        fi
    elif [ "$HTTP_CODE" = "504" ]; then
        echo "    ⏱️  Timeout - file too large or complex"
    elif [ "$HTTP_CODE" = "000" ]; then
        echo "    ❌ Connection failed - check if VoiceInk is running"
    else
        echo "    ❌ Request failed"
        if [ -f /tmp/voiceink_response.json ]; then
            cat /tmp/voiceink_response.json | python3 -m json.tool 2>/dev/null | head -20 | sed 's/^/      /'
        fi
    fi
    
    echo ""
    echo "----------------------------------------"
    echo ""
}

# Create a large test file if needed
create_large_test_file() {
    local size_mb=$1
    local filename="test_${size_mb}mb.mp3"
    
    if [ -f "$filename" ]; then
        echo "Test file $filename already exists"
        return
    fi
    
    echo "Creating ${size_mb}MB test MP3 file..."
    
    # Create long audio using macOS say command
    TEXT=""
    for i in {1..100}; do
        TEXT="$TEXT This is test content number $i for large file testing. "
    done
    
    say -o test_temp.aiff "$TEXT"
    
    if command -v ffmpeg &> /dev/null; then
        # Convert to MP3 and loop to reach desired size
        ffmpeg -i test_temp.aiff -acodec mp3 -ab 128k -af "aloop=loop=10:size=2e+09" -t $((size_mb * 8)) "$filename" 2>/dev/null
        rm test_temp.aiff
        echo "✓ Created $filename"
    else
        echo "❌ ffmpeg not found. Install with: brew install ffmpeg"
        rm test_temp.aiff
        return 1
    fi
}

# Check API health first
echo "Checking VoiceInk API status..."
HEALTH=$(curl -s "$BASE_URL/health" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "❌ VoiceInk API is not running on port $PORT"
    echo "   Please start VoiceInk and enable the API server"
    exit 1
fi

echo "✅ VoiceInk API is running"
MODEL_LOADED=$(echo "$HEALTH" | python3 -c "import sys, json; print(json.load(sys.stdin).get('transcription', {}).get('modelLoaded', False))" 2>/dev/null)
if [ "$MODEL_LOADED" != "True" ]; then
    echo "⚠️  Warning: No transcription model loaded"
fi

MAX_SIZE=$(echo "$HEALTH" | python3 -c "import sys, json; print(json.load(sys.stdin).get('maxFileSize', 0))" 2>/dev/null)
TIMEOUT=$(echo "$HEALTH" | python3 -c "import sys, json; print(json.load(sys.stdin).get('timeout', 0))" 2>/dev/null)
echo "   Max file size: $((MAX_SIZE / 1024 / 1024))MB"
echo "   Timeout: ${TIMEOUT}s"
echo ""
echo "========================================" 
echo ""

# Test with provided file or create test files
if [ -n "$2" ]; then
    # Test with provided file
    test_large_file "$2" "User-provided file"
else
    # Create and test various sizes
    echo "Testing with different file sizes..."
    echo ""
    
    # Test 10MB file
    if [ -f "test_10mb.mp3" ] || create_large_test_file 10; then
        test_large_file "test_10mb.mp3" "10MB test file"
    fi
    
    # Test 30MB file
    if [ -f "test_30mb.mp3" ] || create_large_test_file 30; then
        test_large_file "test_30mb.mp3" "30MB test file"
    fi
    
    # Test 60MB file (your failing case)
    if [ -f "test_60mb.mp3" ] || create_large_test_file 60; then
        test_large_file "test_60mb.mp3" "60MB test file (stress test)"
    fi
fi

# Cleanup
rm -f /tmp/voiceink_response.json

echo ""
echo "Test complete!"
echo ""
echo "Usage:"
echo "  $0 [port] [audio_file]"
echo ""
echo "Examples:"
echo "  $0                          # Test with default sizes"
echo "  $0 5000                     # Use custom port"
echo "  $0 5000 podcast.mp3         # Test specific large file"