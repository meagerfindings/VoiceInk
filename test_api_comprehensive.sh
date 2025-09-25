#!/bin/bash
# Comprehensive API testing script for VoiceInk v1.57+ API server
# Tests various MP3 files with different sizes and characteristics

set -euo pipefail

BASE_URL="http://localhost:5000"
RESULTS_FILE="test_results.json"
LOG_FILE="api_test.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Initialize log
echo "$(date): Starting comprehensive API tests" > "$LOG_FILE"

# Test counters
TOTAL_TESTS=0
SUCCESSFUL_TESTS=0
FAILED_TESTS=0

# Function to log with timestamp
log() {
    echo "$(date '+%H:%M:%S'): $1" | tee -a "$LOG_FILE"
}

# Function to test health endpoint
test_health() {
    log "Testing health endpoint..."
    if response=$(curl -s "$BASE_URL/health" 2>&1); then
        if echo "$response" | grep -q '"status":"healthy"'; then
            echo -e "${GREEN}✅ Health Check: PASSED${NC}"
            log "Health check successful: $response"
            return 0
        else
            echo -e "${RED}❌ Health Check: Unexpected response${NC}"
            log "Health check failed: $response"
            return 1
        fi
    else
        echo -e "${RED}❌ Health Check: Connection failed${NC}"
        log "Health check connection failed: $response"
        return 1
    fi
}

# Function to get file size in MB
get_file_size_mb() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local size_bytes
        size_bytes=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
        echo "scale=2; $size_bytes / 1024 / 1024" | bc -l
    else
        echo "0"
    fi
}

# Function to test transcription of a single file
test_transcribe_file() {
    local file="$1"
    local expected_success="${2:-true}"
    local filename
    filename=$(basename "$file")
    local file_size_mb
    file_size_mb=$(get_file_size_mb "$file")

    if [[ ! -f "$file" ]]; then
        echo -e "${YELLOW}⚠️  Skipping missing file: $filename${NC}"
        return 0
    fi

    log "Testing transcription: $filename (${file_size_mb}MB)"
    echo -e "${BLUE}🎤 Testing: $filename (${file_size_mb}MB)${NC}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    local start_time
    start_time=$(date +%s)

    # Use timeout to prevent hanging (20 minutes max)
    if timeout 1200 curl -s -X POST \
        -H "Content-Type: multipart/form-data" \
        -F "file=@$file" \
        "$BASE_URL/api/transcribe" \
        -o "response_$filename.json" \
        -w "HTTP_STATUS:%{http_code}\nTIME_TOTAL:%{time_total}\nSIZE_DOWNLOAD:%{size_download}\n" \
        > "curl_stats_$filename.txt" 2>&1; then

        local end_time
        end_time=$(date +%s)
        local processing_time
        processing_time=$((end_time - start_time))

        # Parse curl stats
        local http_status
        http_status=$(grep "HTTP_STATUS:" "curl_stats_$filename.txt" | cut -d: -f2)
        local time_total
        time_total=$(grep "TIME_TOTAL:" "curl_stats_$filename.txt" | cut -d: -f2)
        local response_size
        response_size=$(grep "SIZE_DOWNLOAD:" "curl_stats_$filename.txt" | cut -d: -f2)

        if [[ "$http_status" == "200" ]]; then
            SUCCESSFUL_TESTS=$((SUCCESSFUL_TESTS + 1))
            echo -e "${GREEN}✅ SUCCESS: $filename${NC}"
            echo -e "   📊 HTTP Status: $http_status"
            echo -e "   ⏱️  Processing time: ${processing_time}s (curl: ${time_total}s)"
            echo -e "   📦 Response size: ${response_size} bytes"

            # Try to parse and display transcription result
            if [[ -f "response_$filename.json" ]]; then
                # Check if it's valid JSON and extract key info
                if jq empty "response_$filename.json" 2>/dev/null; then
                    local success
                    success=$(jq -r '.success // false' "response_$filename.json")
                    local text_length
                    text_length=$(jq -r '.text | length' "response_$filename.json" 2>/dev/null || echo "0")
                    local model
                    model=$(jq -r '.metadata.model // "unknown"' "response_$filename.json")
                    local enhanced
                    enhanced=$(jq -r '.metadata.enhanced // false' "response_$filename.json")

                    echo -e "   📝 Transcription Success: $success"
                    echo -e "   📏 Text length: $text_length chars"
                    echo -e "   🤖 Model: $model"
                    echo -e "   ✨ Enhanced: $enhanced"

                    # Show text preview
                    local text_preview
                    text_preview=$(jq -r '.text // ""' "response_$filename.json" | head -c 100 | tr '\n' ' ')
                    if [[ -n "$text_preview" ]]; then
                        echo -e "   💬 Text: \"$text_preview...\""
                    fi
                else
                    echo -e "${YELLOW}⚠️  Response is not valid JSON${NC}"
                    head -c 200 "response_$filename.json" | tr '\n' ' '
                    echo
                fi
            fi

            log "SUCCESS: $filename - ${processing_time}s, ${response_size} bytes"
        else
            FAILED_TESTS=$((FAILED_TESTS + 1))
            echo -e "${RED}❌ FAILED: $filename - Status $http_status${NC}"
            echo -e "   ⏱️  Processing time: ${processing_time}s"

            # Show error response if available
            if [[ -f "response_$filename.json" ]]; then
                echo -e "   📄 Response:"
                head -c 300 "response_$filename.json"
                echo
            fi

            log "FAILED: $filename - Status $http_status, ${processing_time}s"
        fi

        # Clean up temp files
        rm -f "curl_stats_$filename.txt"

    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "${RED}⏰ TIMEOUT: $filename after 20 minutes${NC}"
        log "TIMEOUT: $filename after 20 minutes"

        # Clean up any partial response files
        rm -f "response_$filename.json" "curl_stats_$filename.txt"
    fi

    echo
}

# Function to test concurrent requests
test_concurrent_requests() {
    local file="$1"
    local num_requests="${2:-2}"
    local filename
    filename=$(basename "$file")

    if [[ ! -f "$file" ]]; then
        echo -e "${YELLOW}⚠️  Skipping concurrent test - file missing: $filename${NC}"
        return 0
    fi

    echo -e "${BLUE}🔄 Testing $num_requests concurrent requests with $filename${NC}"
    log "Starting concurrent test with $num_requests requests using $filename"

    # Start requests in background
    local pids=()
    for i in $(seq 1 $num_requests); do
        {
            timeout 1200 curl -s -X POST \
                -H "Content-Type: multipart/form-data" \
                -F "file=@$file" \
                "$BASE_URL/api/transcribe" \
                -o "concurrent_response_${i}_$filename.json" \
                -w "HTTP_STATUS:%{http_code}\nTIME_TOTAL:%{time_total}\n" \
                > "concurrent_stats_${i}_$filename.txt" 2>&1
        } &
        pids+=($!)
        log "Started concurrent request $i (PID: $!)"
    done

    # Wait for all requests to complete
    local start_concurrent
    start_concurrent=$(date +%s)

    for i in "${!pids[@]}"; do
        local pid=${pids[$i]}
        echo "Waiting for concurrent request $((i+1)) (PID: $pid)..."
        if wait "$pid"; then
            local status
            status=$(grep "HTTP_STATUS:" "concurrent_stats_$((i+1))_$filename.txt" 2>/dev/null | cut -d: -f2 || echo "ERROR")
            local time_total
            time_total=$(grep "TIME_TOTAL:" "concurrent_stats_$((i+1))_$filename.txt" 2>/dev/null | cut -d: -f2 || echo "ERROR")

            if [[ "$status" == "200" ]]; then
                echo -e "${GREEN}✅ Concurrent request $((i+1)): SUCCESS (${time_total}s)${NC}"
            else
                echo -e "${RED}❌ Concurrent request $((i+1)): FAILED (Status: $status)${NC}"
            fi
        else
            echo -e "${RED}❌ Concurrent request $((i+1)): Process failed${NC}"
        fi
    done

    local end_concurrent
    end_concurrent=$(date +%s)
    local concurrent_time
    concurrent_time=$((end_concurrent - start_concurrent))

    echo -e "${BLUE}🔄 Concurrent test completed in ${concurrent_time}s${NC}"
    log "Concurrent test completed in ${concurrent_time}s"

    # Clean up concurrent test files
    rm -f concurrent_response_*_$filename.json concurrent_stats_*_$filename.txt
    echo
}

# Function to create a corrupted MP3 for error testing
create_test_files() {
    log "Creating test files for error handling..."

    # Create a fake MP3 file with just text content
    echo "This is not a real MP3 file" > fake_mp3.mp3

    # Create a file with null bytes
    dd if=/dev/zero of=null_bytes.mp3 bs=1024 count=1 2>/dev/null

    # Create an empty file
    touch empty.mp3

    echo -e "${YELLOW}📁 Created test files for error handling${NC}"
}

# Function to test error handling
test_error_handling() {
    echo -e "${BLUE}🧪 Testing Error Handling${NC}"
    log "Testing error handling with malformed files"

    # Test with fake MP3
    echo -e "${YELLOW}Testing fake MP3 file...${NC}"
    test_transcribe_file "fake_mp3.mp3" false

    # Test with null bytes file
    echo -e "${YELLOW}Testing null bytes MP3 file...${NC}"
    test_transcribe_file "null_bytes.mp3" false

    # Test with empty file
    echo -e "${YELLOW}Testing empty MP3 file...${NC}"
    test_transcribe_file "empty.mp3" false

    # Clean up test files
    rm -f fake_mp3.mp3 null_bytes.mp3 empty.mp3
}

# Function to print summary
print_summary() {
    echo
    echo "="*80
    echo -e "${BLUE}📊 TEST RESULTS SUMMARY${NC}"
    echo "="*80

    echo "Total Tests: $TOTAL_TESTS"
    echo -e "${GREEN}✅ Successful: $SUCCESSFUL_TESTS${NC}"
    echo -e "${RED}❌ Failed: $FAILED_TESTS${NC}"

    if [[ $TOTAL_TESTS -gt 0 ]]; then
        local success_rate
        success_rate=$((SUCCESSFUL_TESTS * 100 / TOTAL_TESTS))
        echo "Success Rate: ${success_rate}%"
    fi

    echo
    echo -e "${BLUE}📄 Response files generated:${NC}"
    ls -la response_*.json 2>/dev/null || echo "No response files found"

    echo
    log "Test summary: $TOTAL_TESTS total, $SUCCESSFUL_TESTS successful, $FAILED_TESTS failed"
}

# Main testing function
main() {
    echo -e "${BLUE}🧪 COMPREHENSIVE VOICEINK API TESTING${NC}"
    echo "="*50

    # Test health endpoint first
    if ! test_health; then
        echo -e "${RED}❌ API server is not healthy. Exiting.${NC}"
        exit 1
    fi

    echo

    # Create error test files
    create_test_files

    # Define test files by category
    echo -e "${BLUE}📁 Testing Small Files (<1MB)${NC}"
    test_transcribe_file "test_audio.mp3"      # 66KB
    test_transcribe_file "test_30sec.mp3"     # 496KB

    echo -e "${BLUE}📁 Testing Medium Files (1-10MB)${NC}"
    test_transcribe_file "test_1min.mp3"        # 939KB
    test_transcribe_file "test_1min_podcast.mp3" # 906KB
    test_transcribe_file "test_2min.mp3"        # 1.7MB
    test_transcribe_file "test_5min.mp3"        # 4.1MB
    test_transcribe_file "mp3_7m50.mp3"         # 7.2MB
    test_transcribe_file "long_8min.mp3"        # 10MB

    echo -e "${BLUE}📁 Testing Large Files (>10MB) - Expected to fail due to API limits${NC}"
    test_transcribe_file "test_large.mp3" false     # 20MB - should fail
    test_transcribe_file "RPF0154-529_Plans_Pt_2.mp3" false # 33MB - should fail

    # Test error handling
    test_error_handling

    # Test concurrent requests with a small file
    if [[ -f "test_audio.mp3" ]]; then
        test_concurrent_requests "test_audio.mp3" 2
    fi

    # Print summary
    print_summary

    log "Testing completed"
}

# Check if bc is available for calculations
if ! command -v bc &> /dev/null; then
    echo -e "${YELLOW}⚠️  'bc' not found, file size calculations may not work${NC}"
fi

# Check if jq is available for JSON parsing
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}⚠️  'jq' not found, JSON parsing will be limited${NC}"
fi

# Run main function
main "$@"