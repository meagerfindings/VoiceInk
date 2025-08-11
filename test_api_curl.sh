#!/bin/bash

echo "======================================="
echo "VoiceInk API Test Script"
echo "======================================="

API_URL="http://localhost:5000"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "\n${YELLOW}1. Testing Health Endpoint${NC}"
echo "--------------------------------------"
health_response=$(curl -s "${API_URL}/health" 2>/dev/null)
if [ $? -eq 0 ] && [ ! -z "$health_response" ]; then
    echo -e "${GREEN}✅ Health endpoint accessible${NC}"
    echo "$health_response" | python3 -m json.tool 2>/dev/null || echo "$health_response"
else
    echo -e "${RED}❌ API server not accessible${NC}"
    echo "Please ensure:"
    echo "  1. VoiceInk is running"
    echo "  2. API server is enabled in Settings > API"
    echo "  3. Port 7777 is not blocked"
    exit 1
fi

echo -e "\n${YELLOW}2. Testing Basic Transcription${NC}"
echo "--------------------------------------"
if [ -f "test_short.wav" ]; then
    echo "Sending test_short.wav for transcription..."
    response=$(curl -s -X POST "${API_URL}/api/transcribe" \
        -F "file=@test_short.wav" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        success=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
        if [ "$success" = "True" ]; then
            echo -e "${GREEN}✅ Transcription successful${NC}"
            echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f\"Text: {data.get('text', '')[:100]}...\")
metadata = data.get('metadata', {})
print(f\"Model: {metadata.get('model')}\")
print(f\"Duration: {metadata.get('duration', 0):.2f}s\")
print(f\"Processing: {metadata.get('processingTime', 0):.2f}s\")
" 2>/dev/null || echo "$response"
        else
            echo -e "${RED}❌ Transcription failed${NC}"
            echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
        fi
    else
        echo -e "${RED}❌ Failed to send request${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  test_short.wav not found${NC}"
fi

echo -e "\n${YELLOW}3. Testing Transcription with Diarization${NC}"
echo "--------------------------------------"
if [ -f "conversation.wav" ]; then
    echo "Sending conversation.wav with diarization enabled..."
    response=$(curl -s -X POST "${API_URL}/api/transcribe" \
        -F "enable_diarization=true" \
        -F "diarization_mode=balanced" \
        -F "min_speakers=2" \
        -F "max_speakers=4" \
        -F "file=@conversation.wav" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        success=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
        if [ "$success" = "True" ]; then
            echo -e "${GREEN}✅ Transcription with diarization successful${NC}"
            echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f\"Text: {data.get('text', '')[:100]}...\")
print(f\"Speakers detected: {data.get('numSpeakers', 0)}\")
segments = data.get('segments', [])[:3]
if segments:
    print(f\"\\nFirst {len(segments)} segments:\")
    for seg in segments:
        print(f\"  [{seg['start']:.1f}-{seg['end']:.1f}] {seg['speaker']}: {seg['text'][:40]}...\")
metadata = data.get('metadata', {})
print(f\"\\nDiarization method: {metadata.get('diarizationMethod', 'N/A')}\")
print(f\"Processing time: {metadata.get('processingTime', 0):.2f}s\")
" 2>/dev/null || echo "$response" | head -20
        else
            echo -e "${RED}❌ Transcription with diarization failed${NC}"
            echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response" | head -20
        fi
    else
        echo -e "${RED}❌ Failed to send request${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  conversation.wav not found${NC}"
fi

echo -e "\n======================================="
echo "Test Complete"
echo "======================================="