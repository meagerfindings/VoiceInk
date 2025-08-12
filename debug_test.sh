#!/bin/bash

# VoiceInk API Debug Test Script
# This script helps identify where exactly the API hangs

echo "🔍 VoiceInk API Debug Test - Identifying Hang Location"
echo "======================================================="
echo ""

# Test 1: Basic connection test
echo "📡 Test 1: Basic Connection Test"
echo "Checking if port 5000 is accepting connections..."
if nc -z localhost 5000; then
    echo "✅ Port 5000 is accepting connections"
else
    echo "❌ Port 5000 is not accepting connections"
    echo "Please start VoiceInk and enable API server in Settings > API"
    exit 1
fi

echo ""

# Test 2: Debug endpoint with timeout
echo "🔧 Test 2: Debug Endpoint Test (30 second timeout)"
echo "Testing minimal /debug endpoint to isolate hang point..."
echo "Expected response: {\"debug\":\"minimal\",\"timestamp\":...,\"connection_id\":\"...\"}"
echo ""

echo "Running: curl -m 30 -v http://localhost:5000/debug"
echo "=========================================="

start_time=$(date +%s)
curl -m 30 -w "\n\n📊 CONNECTION METRICS:\nHTTP Status: %{http_code}\nTotal Time: %{time_total}s\nConnect Time: %{time_connect}s\nBytes Received: %{size_download}\n" http://localhost:5000/debug
end_time=$(date +%s)
duration=$((end_time - start_time))

echo ""
echo "⏱️ Test Duration: ${duration} seconds"

if [ $duration -ge 25 ]; then
    echo ""
    echo "🔴 HANG DETECTED: Request took $duration seconds (near timeout)"
    echo ""
    echo "📋 DEBUGGING INSTRUCTIONS:"
    echo "1. Check Xcode console for debug logs"
    echo "2. Look for the LAST successful log message before hang:"
    echo "   🟢 NEW CONNECTION: CONN-XXXX - Connection establishment"
    echo "   🔵 CONN-XXXX: Calling connection.receive() - Starting to read"
    echo "   🔵 CONN-XXXX: Received callback - Data received"
    echo "   🟡 HEADER PARSE: Found header separator - Headers parsed"
    echo "   🟢 ROUTE: Processing GET /debug - Request routing"
    echo "   🔧 DEBUG: Calling connection.send() - Response sending"
    echo "   🔧 CONN-XXXX: Send completion handler called - Completion"
    echo ""
    echo "3. The hang occurs immediately AFTER the last successful message"
    echo "4. Check for any error messages (🔴) in the logs"
    echo "5. Note if timeout message appears: 🔴 TIMEOUT: CONN-XXXX hung for 30 seconds"
    echo ""
    echo "📞 NEXT STEPS:"
    echo "- If logs stop after 'Calling connection.receive()' → Network layer issue"
    echo "- If logs stop after 'Received callback' → Data processing issue"
    echo "- If logs stop after 'Found header separator' → Header parsing issue"
    echo "- If logs stop after 'Processing GET /debug' → Request routing issue"
    echo "- If logs stop after 'Calling connection.send()' → Response sending issue"
    echo "- If no timeout message → Complete hang, timeout system broken"
    echo ""
else
    echo "✅ Request completed in reasonable time"
    echo "The hang might be intermittent or resolved"
fi

echo ""
echo "🔍 Additional Connection State Check:"
echo "======================================"
lsof -i :5000 | head -10

echo ""
echo "Debug test completed. Check Xcode console for detailed debug logs."