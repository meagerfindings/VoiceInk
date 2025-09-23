#!/bin/bash

# VoiceInk Transcription Cancellation Test Script
# Tests the complete cancellation fix implementation

echo "🔧 VoiceInk Cancellation Fix Testing"
echo "===================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
API_URL="http://localhost:8081"
TEST_FILE="mp3_7m50.mp3"
LOG_FILE="test_cancellation_$(date +%Y%m%d_%H%M%S).log"

# Function to check if API is running
check_api() {
    echo -n "Checking API server status... "
    if curl -s "$API_URL/status" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Running${NC}"
        return 0
    else
        echo -e "${RED}✗ Not running${NC}"
        return 1
    fi
}

# Function to test normal transcription
test_normal_transcription() {
    echo -e "\n📝 Testing normal transcription..."
    echo "File: $TEST_FILE (7.2MB, ~7min 50sec)"
    
    if [ ! -f "$TEST_FILE" ]; then
        echo -e "${RED}✗ Test file $TEST_FILE not found${NC}"
        return 1
    fi
    
    echo "Starting transcription (this may take a few minutes)..."
    local start_time=$(date +%s)
    
    curl -X POST "$API_URL/transcribe" \
         -F "audio=@$TEST_FILE" \
         -H "Content-Type: multipart/form-data" \
         -w "\nHTTP Status: %{http_code}\nTime: %{time_total}s\n" \
         > "transcription_result_$(date +%H%M%S).json" 2>> "$LOG_FILE"
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo -e "${GREEN}✓ Transcription completed in ${duration}s${NC}"
    return 0
}

# Function to test cancellation
test_cancellation() {
    echo -e "\n❌ Testing transcription cancellation..."
    echo "File: $TEST_FILE (7.2MB)"
    
    if [ ! -f "$TEST_FILE" ]; then
        echo -e "${RED}✗ Test file $TEST_FILE not found${NC}"
        return 1
    fi
    
    echo "Starting transcription in background..."
    
    # Start transcription in background
    curl -X POST "$API_URL/transcribe" \
         -F "audio=@$TEST_FILE" \
         -H "Content-Type: multipart/form-data" \
         > "cancelled_result_$(date +%H%M%S).json" 2>> "$LOG_FILE" &
    
    local transcribe_pid=$!
    echo "Transcription started (PID: $transcribe_pid)"
    
    # Wait 3 seconds to let transcription start
    echo "Waiting 3 seconds for transcription to start..."
    sleep 3
    
    # Send cancel request
    echo "Sending cancellation request..."
    local cancel_start=$(date +%s)
    
    curl -X POST "$API_URL/cancel" \
         -w "Cancel HTTP Status: %{http_code}\n" \
         2>> "$LOG_FILE"
    
    # Monitor for a few seconds to see if cancellation takes effect
    echo "Monitoring cancellation response..."
    for i in {1..10}; do
        if ! jobs %1 > /dev/null 2>&1; then
            local cancel_end=$(date +%s)
            local cancel_time=$((cancel_end - cancel_start))
            echo -e "${GREEN}✓ Transcription cancelled in ${cancel_time}s${NC}"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    
    # If still running, force kill
    if jobs %1 > /dev/null 2>&1; then
        echo -e "\n${YELLOW}⚠ Cancellation took longer than expected, killing process${NC}"
        kill $transcribe_pid 2>/dev/null
        return 1
    fi
}

# Function to monitor CPU usage
monitor_cpu() {
    echo -e "\n💻 CPU Usage Monitoring Test"
    
    local voiceink_pid=$(pgrep VoiceInk)
    if [ -z "$voiceink_pid" ]; then
        echo -e "${RED}✗ VoiceInk process not found${NC}"
        return 1
    fi
    
    echo "VoiceInk PID: $voiceink_pid"
    echo "Monitoring CPU usage during test..."
    
    # Monitor CPU for 30 seconds
    echo "CPU% Time"
    for i in {1..30}; do
        local cpu_usage=$(ps -p $voiceink_pid -o %cpu= | xargs 2>/dev/null)
        if [ -n "$cpu_usage" ]; then
            printf "%4s %2ds\n" "$cpu_usage" "$i"
        fi
        sleep 1
    done
}

# Main test sequence
main() {
    echo "Log file: $LOG_FILE"
    echo ""
    
    # Check if API is running
    if ! check_api; then
        echo -e "${RED}Please start VoiceInk application first${NC}"
        exit 1
    fi
    
    echo -e "\n🔬 Running Test Suite..."
    
    # Test 1: Normal transcription
    if test_normal_transcription; then
        echo -e "${GREEN}✓ Test 1 Passed: Normal transcription works${NC}"
    else
        echo -e "${RED}✗ Test 1 Failed: Normal transcription failed${NC}"
    fi
    
    # Wait between tests
    echo -e "\nWaiting 5 seconds before cancellation test..."
    sleep 5
    
    # Test 2: Cancellation
    if test_cancellation; then
        echo -e "${GREEN}✓ Test 2 Passed: Cancellation works properly${NC}"
    else
        echo -e "${RED}✗ Test 2 Failed: Cancellation issues detected${NC}"
    fi
    
    # Test 3: CPU monitoring (optional)
    read -p "Run CPU monitoring test? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        monitor_cpu
    fi
    
    echo -e "\n📋 Test Summary:"
    echo "- Test files created with timestamp"
    echo "- Logs written to: $LOG_FILE"
    echo "- Check results for detailed analysis"
    
    echo -e "\n🎯 Expected Results:"
    echo "✅ Normal transcription should complete successfully"
    echo "✅ Cancellation should stop transcription within 1-3 seconds"
    echo "✅ CPU usage should drop to normal levels after cancel"
    echo "✅ No background processes should continue after cancellation"
}

# Run tests
main "$@"
