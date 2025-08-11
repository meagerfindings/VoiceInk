#!/bin/bash

echo "Testing diarization parameter parsing..."

# Create a simple test without audio first
echo "Test 1: Simple form data test"
curl -X POST "http://localhost:5000/api/transcribe" \
    -F "enable_diarization=true" \
    -F "diarization_mode=quality" \
    -F "test=hello" \
    -s -w "\nHTTP Status: %{http_code}\n"

echo -e "\n-------------------\n"

# Test with a small audio file
echo "Test 2: With audio file"
if [ -f "test_short.wav" ]; then
    # Create a test that shows what's being sent
    curl -X POST "http://localhost:5000/api/transcribe" \
        -F "enable_diarization=true" \
        -F "diarization_mode=quality" \
        -F "min_speakers=2" \
        -F "max_speakers=4" \
        -F "use_tinydiarize=true" \
        -F "file=@test_short.wav" \
        --trace-ascii trace.txt \
        -s > response.json
    
    echo "Response:"
    cat response.json | python3 -m json.tool | head -20
    
    echo -e "\nForm fields sent (from trace):"
    grep -A1 'Content-Disposition: form-data; name=' trace.txt | grep -v "^--$" | head -20
else
    echo "test_short.wav not found"
fi