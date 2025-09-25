#!/usr/bin/env python3
"""
Comprehensive API testing script for VoiceInk v1.57+ API server
Tests various MP3 files with different sizes and characteristics
"""

import requests
import time
import json
import os
import sys
from pathlib import Path
from typing import Dict, List, Tuple, Optional

class APITester:
    def __init__(self, base_url: str = "http://localhost:5000"):
        self.base_url = base_url
        self.results: List[Dict] = []

    def test_health(self) -> bool:
        """Test the health endpoint"""
        try:
            response = requests.get(f"{self.base_url}/health", timeout=10)
            if response.status_code == 200:
                health_data = response.json()
                print(f"✅ Health Check: {health_data}")
                return True
            else:
                print(f"❌ Health Check Failed: {response.status_code}")
                return False
        except Exception as e:
            print(f"❌ Health Check Error: {e}")
            return False

    def test_transcribe_file(self, file_path: str, expected_success: bool = True) -> Dict:
        """Test transcription of a single file"""
        file_name = os.path.basename(file_path)
        file_size_mb = os.path.getsize(file_path) / (1024 * 1024)

        print(f"\n🎤 Testing: {file_name} ({file_size_mb:.1f} MB)")

        start_time = time.time()

        try:
            with open(file_path, 'rb') as f:
                files = {'file': (file_name, f, 'audio/mpeg')}
                response = requests.post(
                    f"{self.base_url}/api/transcribe",
                    files=files,
                    timeout=1200  # 20 minutes timeout
                )

            end_time = time.time()
            processing_time = end_time - start_time

            result = {
                'file': file_name,
                'size_mb': file_size_mb,
                'status_code': response.status_code,
                'processing_time_seconds': processing_time,
                'expected_success': expected_success,
                'success': response.status_code == 200,
                'response_size': len(response.content) if response.content else 0
            }

            if response.status_code == 200:
                try:
                    json_response = response.json()
                    result['transcription_success'] = json_response.get('success', False)
                    result['text_length'] = len(json_response.get('text', '')) if json_response.get('text') else 0
                    result['enhanced'] = json_response.get('metadata', {}).get('enhanced', False)
                    result['model'] = json_response.get('metadata', {}).get('model', 'unknown')
                    result['transcription_time'] = json_response.get('metadata', {}).get('transcriptionTime', 0)

                    # Print summary
                    print(f"✅ SUCCESS: {file_name}")
                    print(f"   📝 Transcribed {result['text_length']} chars in {processing_time:.1f}s")
                    print(f"   🤖 Model: {result['model']}")
                    if result['enhanced']:
                        print(f"   ✨ AI Enhanced")

                    # Show first 100 chars of transcription
                    if json_response.get('text'):
                        text_preview = json_response['text'][:100].replace('\n', ' ')
                        print(f"   💬 Text: \"{text_preview}{'...' if len(json_response['text']) > 100 else ''}\"")

                except json.JSONDecodeError as e:
                    result['json_error'] = str(e)
                    print(f"❌ JSON Parse Error: {e}")
                    print(f"   📄 Raw response: {response.text[:200]}...")

            else:
                print(f"❌ FAILED: {file_name} - Status {response.status_code}")
                print(f"   ⏱️ Processing time: {processing_time:.1f}s")
                print(f"   📄 Response: {response.text[:200]}...")
                result['error_message'] = response.text[:500]

            self.results.append(result)
            return result

        except requests.exceptions.Timeout:
            print(f"⏰ TIMEOUT: {file_name} after 20 minutes")
            result = {
                'file': file_name,
                'size_mb': file_size_mb,
                'status_code': 'TIMEOUT',
                'processing_time_seconds': 1200,  # Max timeout
                'expected_success': expected_success,
                'success': False,
                'error_message': 'Request timeout after 20 minutes'
            }
            self.results.append(result)
            return result

        except Exception as e:
            print(f"❌ ERROR: {file_name} - {str(e)}")
            result = {
                'file': file_name,
                'size_mb': file_size_mb,
                'status_code': 'ERROR',
                'processing_time_seconds': time.time() - start_time,
                'expected_success': expected_success,
                'success': False,
                'error_message': str(e)
            }
            self.results.append(result)
            return result

    def test_concurrent_requests(self, file_path: str, num_requests: int = 3) -> List[Dict]:
        """Test concurrent requests to check for race conditions"""
        print(f"\n🔄 Testing {num_requests} concurrent requests with {os.path.basename(file_path)}")

        import threading
        import queue

        results_queue = queue.Queue()
        threads = []

        def worker():
            result = self.test_transcribe_file(file_path)
            results_queue.put(result)

        # Start all threads
        for i in range(num_requests):
            thread = threading.Thread(target=worker)
            threads.append(thread)
            thread.start()

        # Wait for all threads to complete
        for thread in threads:
            thread.join()

        # Collect results
        concurrent_results = []
        while not results_queue.empty():
            concurrent_results.append(results_queue.get())

        return concurrent_results

    def print_summary(self):
        """Print a summary of all test results"""
        print("\n" + "="*80)
        print("📊 TEST RESULTS SUMMARY")
        print("="*80)

        total_tests = len(self.results)
        successful_tests = sum(1 for r in self.results if r['success'])
        failed_tests = total_tests - successful_tests

        print(f"Total Tests: {total_tests}")
        print(f"✅ Successful: {successful_tests}")
        print(f"❌ Failed: {failed_tests}")
        print(f"Success Rate: {(successful_tests/total_tests)*100:.1f}%" if total_tests > 0 else "0%")

        print("\n📈 Performance Metrics:")
        if self.results:
            processing_times = [r.get('processing_time_seconds', 0) for r in self.results if r.get('processing_time_seconds')]
            if processing_times:
                print(f"   Average processing time: {sum(processing_times)/len(processing_times):.1f}s")
                print(f"   Fastest: {min(processing_times):.1f}s")
                print(f"   Slowest: {max(processing_times):.1f}s")

        print("\n📁 Results by file size:")
        small_files = [r for r in self.results if r.get('size_mb', 0) < 1]
        medium_files = [r for r in self.results if 1 <= r.get('size_mb', 0) < 10]
        large_files = [r for r in self.results if r.get('size_mb', 0) >= 10]

        for category, files, name in [(small_files, "Small (<1MB)"), (medium_files, "Medium (1-10MB)"), (large_files, "Large (≥10MB)")]:
            if files:
                success_rate = sum(1 for f in files if f['success']) / len(files) * 100
                avg_time = sum(f.get('processing_time_seconds', 0) for f in files) / len(files)
                print(f"   {name}: {len(files)} files, {success_rate:.0f}% success, {avg_time:.1f}s avg")

        print("\n❌ Failed Tests:")
        failed_results = [r for r in self.results if not r['success']]
        for result in failed_results:
            print(f"   - {result['file']} ({result['size_mb']:.1f}MB): {result.get('error_message', 'Unknown error')[:100]}")

        # Save detailed results
        with open('api_test_results.json', 'w') as f:
            json.dump(self.results, f, indent=2, default=str)
        print(f"\n💾 Detailed results saved to: api_test_results.json")


def main():
    # Initialize tester
    tester = APITester()

    # Test health endpoint first
    if not tester.test_health():
        print("❌ API server is not healthy. Exiting.")
        sys.exit(1)

    # Define test files by category
    project_root = Path(__file__).parent

    test_files = {
        'small': [  # Under 1MB
            str(project_root / 'test_audio.mp3'),  # 66KB
            str(project_root / 'test_30sec.mp3'),  # 496KB
        ],
        'medium': [  # 1-10MB
            str(project_root / 'test_1min.mp3'),  # 939KB
            str(project_root / 'test_1min_podcast.mp3'),  # 906KB
            str(project_root / 'test_2min.mp3'),  # 1.7MB
            str(project_root / 'test_5min.mp3'),  # 4.1MB
            str(project_root / 'mp3_7m50.mp3'),   # 7.2MB
            str(project_root / 'long_8min.mp3'),  # 10MB
        ],
        'large': [  # Over 10MB - these should fail based on new limits
            str(project_root / 'test_large.mp3'),  # 20MB
            str(project_root / 'RPF0154-529_Plans_Pt_2.mp3'),  # 33MB
        ]
    }

    # Test each category
    print("\n🧪 COMPREHENSIVE API TESTING")
    print("="*50)

    # Test small files (should all succeed)
    print(f"\n📁 Testing Small Files (<1MB)")
    for file_path in test_files['small']:
        if os.path.exists(file_path):
            tester.test_transcribe_file(file_path, expected_success=True)
        else:
            print(f"⚠️  Skipping missing file: {file_path}")

    # Test medium files (should mostly succeed, some may timeout)
    print(f"\n📁 Testing Medium Files (1-10MB)")
    for file_path in test_files['medium']:
        if os.path.exists(file_path):
            tester.test_transcribe_file(file_path, expected_success=True)
        else:
            print(f"⚠️  Skipping missing file: {file_path}")

    # Test large files (should fail due to size limits)
    print(f"\n📁 Testing Large Files (>10MB) - Expected to fail due to API limits")
    for file_path in test_files['large']:
        if os.path.exists(file_path):
            tester.test_transcribe_file(file_path, expected_success=False)
        else:
            print(f"⚠️  Skipping missing file: {file_path}")

    # Test concurrent requests with a small file
    if os.path.exists(test_files['small'][0]):
        tester.test_concurrent_requests(test_files['small'][0], 2)

    # Print summary
    tester.print_summary()

if __name__ == '__main__':
    main()