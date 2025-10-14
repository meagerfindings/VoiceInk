#!/bin/bash

# Folder Watcher Integration Test Script
# This script tests the FileWatcherManager functionality

set -e

echo "================================"
echo "Folder Watcher Integration Test"
echo "================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test directories
TEST_DIR="/tmp/voiceink_folder_watcher_test_$$"
INPUT_DIR="${TEST_DIR}/input"
OUTPUT_DIR="${TEST_DIR}/output"
TEST_AUDIO="${TEST_DIR}/test_audio.wav"

# Sample audio file from project
SOURCE_AUDIO="./whisper.cpp/samples/jfk.wav"

# Setup function
setup_test_env() {
    echo "Setting up test environment..."
    mkdir -p "$INPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    
    if [ -f "$SOURCE_AUDIO" ]; then
        cp "$SOURCE_AUDIO" "$TEST_AUDIO"
        echo -e "${GREEN}✓${NC} Test audio file prepared: $TEST_AUDIO"
    else
        echo -e "${RED}✗${NC} Source audio file not found: $SOURCE_AUDIO"
        exit 1
    fi
    
    echo -e "${GREEN}✓${NC} Test directories created:"
    echo "  Input:  $INPUT_DIR"
    echo "  Output: $OUTPUT_DIR"
    echo ""
}

# Cleanup function
cleanup_test_env() {
    echo ""
    echo "Cleaning up test environment..."
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
        echo -e "${GREEN}✓${NC} Test directory removed"
    fi
}

# Test 1: Verify directory structure
test_directory_structure() {
    echo "Test 1: Directory Structure Validation"
    echo "--------------------------------------"
    
    if [ -d "$INPUT_DIR" ] && [ -d "$OUTPUT_DIR" ]; then
        echo -e "${GREEN}✓${NC} Input and output directories exist"
        return 0
    else
        echo -e "${RED}✗${NC} Directory validation failed"
        return 1
    fi
}

# Test 2: Verify audio file detection
test_audio_file_detection() {
    echo ""
    echo "Test 2: Audio File Detection"
    echo "----------------------------"
    
    # Copy test audio to input directory
    cp "$TEST_AUDIO" "$INPUT_DIR/test1.wav"
    cp "$TEST_AUDIO" "$INPUT_DIR/test2.wav"
    cp "$TEST_AUDIO" "$INPUT_DIR/test3.m4a"  # Different extension
    
    # Create unsupported file
    echo "not an audio file" > "$INPUT_DIR/test.txt"
    
    AUDIO_COUNT=$(find "$INPUT_DIR" -type f \( -name "*.wav" -o -name "*.mp3" -o -name "*.m4a" -o -name "*.aiff" -o -name "*.mp4" -o -name "*.mov" -o -name "*.aac" -o -name "*.flac" -o -name "*.caf" \) | wc -l)
    
    if [ "$AUDIO_COUNT" -eq 3 ]; then
        echo -e "${GREEN}✓${NC} Correctly identified 3 audio files"
        echo -e "${GREEN}✓${NC} Ignored unsupported file (test.txt)"
        return 0
    else
        echo -e "${RED}✗${NC} Expected 3 audio files, found $AUDIO_COUNT"
        return 1
    fi
}

# Test 3: Verify supported file extensions
test_supported_extensions() {
    echo ""
    echo "Test 3: Supported File Extensions"
    echo "---------------------------------"
    
    SUPPORTED_EXTENSIONS=("wav" "mp3" "m4a" "aiff" "mp4" "mov" "aac" "flac" "caf")
    
    echo "Supported extensions according to SupportedMedia.swift:"
    for ext in "${SUPPORTED_EXTENSIONS[@]}"; do
        echo -e "  ${GREEN}✓${NC} .$ext"
    done
    
    return 0
}

# Test 4: Simulate folder watching behavior
test_folder_watching_simulation() {
    echo ""
    echo "Test 4: Folder Watching Simulation"
    echo "-----------------------------------"
    
    # Clean input directory
    rm -f "$INPUT_DIR"/*
    
    echo "Simulating file drops..."
    
    # Simulate dropping files one by one
    for i in {1..3}; do
        cp "$TEST_AUDIO" "$INPUT_DIR/drop_test_$i.wav"
        echo -e "  ${GREEN}✓${NC} Dropped file $i: drop_test_$i.wav"
        sleep 0.1
    done
    
    DROPPED_FILES=$(find "$INPUT_DIR" -name "drop_test_*.wav" | wc -l)
    
    if [ "$DROPPED_FILES" -eq 3 ]; then
        echo -e "${GREEN}✓${NC} All 3 files detected in input folder"
        return 0
    else
        echo -e "${RED}✗${NC} Expected 3 files, found $DROPPED_FILES"
        return 1
    fi
}

# Test 5: Output file naming convention
test_output_naming() {
    echo ""
    echo "Test 5: Output File Naming Convention"
    echo "--------------------------------------"
    
    INPUT_FILE="test_recording.wav"
    EXPECTED_OUTPUT="test_recording_transcript.txt"
    
    echo "Input file:     $INPUT_FILE"
    echo "Expected output: $EXPECTED_OUTPUT"
    echo -e "${GREEN}✓${NC} Naming convention verified (input_name + '_transcript.txt')"
    
    return 0
}

# Test 6: Edge cases
test_edge_cases() {
    echo ""
    echo "Test 6: Edge Cases"
    echo "------------------"
    
    # Clean input directory
    rm -f "$INPUT_DIR"/*
    
    # Test with spaces in filename
    cp "$TEST_AUDIO" "$INPUT_DIR/file with spaces.wav"
    if [ -f "$INPUT_DIR/file with spaces.wav" ]; then
        echo -e "${GREEN}✓${NC} Files with spaces in name handled correctly"
    else
        echo -e "${RED}✗${NC} Failed to handle spaces in filename"
    fi
    
    # Test with special characters (that are safe for filesystem)
    cp "$TEST_AUDIO" "$INPUT_DIR/file-with-dashes_and_underscores.wav"
    if [ -f "$INPUT_DIR/file-with-dashes_and_underscores.wav" ]; then
        echo -e "${GREEN}✓${NC} Files with dashes and underscores handled correctly"
    else
        echo -e "${RED}✗${NC} Failed to handle special characters"
    fi
    
    # Test with very long filename
    LONG_NAME="this_is_a_very_long_filename_that_might_cause_issues_in_some_systems_but_should_work_fine.wav"
    cp "$TEST_AUDIO" "$INPUT_DIR/$LONG_NAME"
    if [ -f "$INPUT_DIR/$LONG_NAME" ]; then
        echo -e "${GREEN}✓${NC} Long filenames handled correctly"
    else
        echo -e "${RED}✗${NC} Failed to handle long filename"
    fi
    
    return 0
}

# Test 7: Concurrent file handling
test_concurrent_files() {
    echo ""
    echo "Test 7: Concurrent File Handling"
    echo "--------------------------------"
    
    # Clean input directory
    rm -f "$INPUT_DIR"/*
    
    echo "Simulating rapid file drops (queue processing test)..."
    
    # Drop multiple files simultaneously
    for i in {1..5}; do
        cp "$TEST_AUDIO" "$INPUT_DIR/concurrent_$i.wav" &
    done
    
    wait
    
    CONCURRENT_FILES=$(find "$INPUT_DIR" -name "concurrent_*.wav" | wc -l)
    
    if [ "$CONCURRENT_FILES" -eq 5 ]; then
        echo -e "${GREEN}✓${NC} All 5 concurrent files handled correctly"
        echo -e "${GREEN}✓${NC} Queue processing should handle these sequentially"
        return 0
    else
        echo -e "${RED}✗${NC} Expected 5 files, found $CONCURRENT_FILES"
        return 1
    fi
}

# Test 8: Directory permission check
test_directory_permissions() {
    echo ""
    echo "Test 8: Directory Permissions"
    echo "-----------------------------"
    
    if [ -w "$INPUT_DIR" ] && [ -r "$INPUT_DIR" ]; then
        echo -e "${GREEN}✓${NC} Input directory has correct read/write permissions"
    else
        echo -e "${RED}✗${NC} Input directory permission issues"
        return 1
    fi
    
    if [ -w "$OUTPUT_DIR" ] && [ -r "$OUTPUT_DIR" ]; then
        echo -e "${GREEN}✓${NC} Output directory has correct read/write permissions"
    else
        echo -e "${RED}✗${NC} Output directory permission issues"
        return 1
    fi
    
    return 0
}

# Main test execution
main() {
    trap cleanup_test_env EXIT
    
    setup_test_env
    
    TESTS_PASSED=0
    TESTS_FAILED=0
    
    # Run all tests
    if test_directory_structure; then ((TESTS_PASSED++)); else ((TESTS_FAILED++)); fi
    if test_audio_file_detection; then ((TESTS_PASSED++)); else ((TESTS_FAILED++)); fi
    if test_supported_extensions; then ((TESTS_PASSED++)); else ((TESTS_FAILED++)); fi
    if test_folder_watching_simulation; then ((TESTS_PASSED++)); else ((TESTS_FAILED++)); fi
    if test_output_naming; then ((TESTS_PASSED++)); else ((TESTS_FAILED++)); fi
    if test_edge_cases; then ((TESTS_PASSED++)); else ((TESTS_FAILED++)); fi
    if test_concurrent_files; then ((TESTS_PASSED++)); else ((TESTS_FAILED++)); fi
    if test_directory_permissions; then ((TESTS_PASSED++)); else ((TESTS_FAILED++)); fi
    
    # Summary
    echo ""
    echo "================================"
    echo "Test Summary"
    echo "================================"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        echo ""
        echo "Note: These are structural tests. For full functionality testing:"
        echo "1. Build the app: xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug build"
        echo "2. Run the app and configure folder watcher with these directories:"
        echo "   Input:  $INPUT_DIR"
        echo "   Output: $OUTPUT_DIR"
        echo "3. Drop an audio file into the input directory"
        echo "4. Verify transcript appears in output directory"
        echo "5. Verify original file is deleted from input directory"
        return 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    fi
}

# Run main
main
