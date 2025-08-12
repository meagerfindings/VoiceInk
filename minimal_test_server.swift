#!/usr/bin/env swift

import Foundation
import Network

print("🧪 MINIMAL TEST SERVER - Zero MainActor Dependencies")
print("This will prove if MainActor capture is causing NWConnection.receive() to hang")
print("Starting server on port 5001...")

// COMPLETELY ISOLATED - NO MainActor dependencies
class MinimalConnectionHandler {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    
    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        print("✅ Connection handler created - NO MainActor dependencies")
    }
    
    func start() {
        print("🔄 Starting connection handler...")
        readData()
    }
    
    private func readData() {
        print("📥 Calling connection.receive() - should work without MainActor blocking...")
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            print("🎉 CALLBACK EXECUTED! This proves MainActor was the issue")
            
            guard let self = self else { 
                print("❌ Self is nil")
                return 
            }
            
            if let error = error {
                print("🔴 Error: \(error)")
                return
            }
            
            if let data = data {
                print("📦 Received \(data.count) bytes")
                self.buffer.append(data)
                
                // Simple HTTP detection
                if let httpString = String(data: self.buffer, encoding: .utf8),
                   httpString.contains("GET /test") {
                    print("🔍 Detected GET /test request")
                    self.sendSimpleResponse()
                    return
                }
            }
            
            if !isComplete {
                print("🔄 Continuing to read...")
                self.readData()
            }
        }
    }
    
    private func sendSimpleResponse() {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"test\":\"ok\"}"
        let data = response.data(using: .utf8) ?? Data()
        
        print("📤 Sending response: \(data.count) bytes")
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("🔴 Send error: \(error)")
            } else {
                print("✅ Response sent successfully!")
            }
            print("🔚 Closing connection")
        })
    }
}

// MINIMAL SERVER - NO MainActor
class MinimalTestServer {
    private let listener: NWListener
    private let queue: DispatchQueue
    
    init() throws {
        self.queue = DispatchQueue(label: "minimal.server", qos: .userInitiated)
        self.listener = try NWListener(using: .tcp, on: 5001)
    }
    
    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            print("🔗 New connection received")
            
            connection.start(queue: self.queue)
            let handler = MinimalConnectionHandler(connection: connection, queue: self.queue)
            handler.start()
        }
        
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("🟢 Server ready on port 5001")
            case .failed(let error):
                print("🔴 Server failed: \(error)")
            default:
                break
            }
        }
        
        listener.start(queue: queue)
    }
}

// START THE TEST
do {
    let server = try MinimalTestServer()
    server.start()
    
    print("\n🧪 TEST INSTRUCTIONS:")
    print("1. Run: curl http://localhost:5001/test")
    print("2. If you get {\"test\":\"ok\"} → MainActor was the problem!")
    print("3. If it hangs → There's a deeper NWConnection issue")
    print("\nPress Ctrl+C to stop")
    
    // Keep running
    RunLoop.main.run()
} catch {
    print("🔴 Failed to start server: \(error)")
    exit(1)
}