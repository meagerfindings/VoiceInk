import SwiftUI

struct APISettingsView: View {
    @EnvironmentObject private var apiServer: TranscriptionAPIServer
    @State private var port: String = ""
    @State private var apiToken: String = ""
    @State private var allowNetworkAccess = false
    @State private var autoStartAPI = false
    @State private var showingTestInstructions = false
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Status:")
                        .foregroundColor(.secondary)
                    Text(apiServer.isRunning ? "Running" : "Stopped")
                        .foregroundColor(apiServer.isRunning ? .green : .secondary)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    Button(apiServer.isRunning ? "Stop Server" : "Start Server") {
                        if apiServer.isRunning {
                            apiServer.stop()
                        } else {
                            saveSettings()
                            apiServer.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(apiServer.isRunning ? .red : .blue)
                }
                
                if let error = apiServer.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            } header: {
                Text("API Server")
            }
            
            Section {
                HStack {
                    Text("Port:")
                    TextField("5000", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: port) { newValue in
                            // Validate port number
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered != newValue {
                                port = filtered
                            }
                        }
                        .disabled(apiServer.isRunning)
                }
                
                Toggle("Allow Network Access", isOn: $allowNetworkAccess)
                    .onChange(of: allowNetworkAccess) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "APIServerAllowNetworkAccess")
                        if apiServer.isRunning {
                            // Restart server with new settings
                            apiServer.stop()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                apiServer.start()
                            }
                        }
                    }
                
                if allowNetworkAccess {
                    Text("When enabled, the API will be accessible from other devices on your network. Otherwise, it's only accessible from localhost.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Toggle("Auto-start on Launch", isOn: $autoStartAPI)
                    .onChange(of: autoStartAPI) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "APIServerAutoStart")
                    }
                
                HStack {
                    Text("API Token (Optional):")
                    SecureField("Enter token", text: $apiToken)
                        .textFieldStyle(.roundedBorder)
                        .disabled(apiServer.isRunning)
                }
                
                if !apiToken.isEmpty {
                    Text("Requests will need to include 'Authorization: Bearer YOUR_TOKEN' header")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Configuration")
            } footer: {
                Text("Configure the API server settings. Changes require restarting the server.")
                    .font(.caption)
            }
            
            Section {
                if apiServer.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Endpoint:")
                            .font(.headline)
                        
                        let baseURL = allowNetworkAccess ? 
                            "http://YOUR_IP:\(port)" : 
                            "http://localhost:\(port)"
                        
                        Text("\(baseURL)/api/transcribe")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        
                        Text("\(baseURL)/health")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    
                    Button("Show Test Instructions") {
                        showingTestInstructions = true
                    }
                }
            } header: {
                Text("API Information")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadSettings()
        }
        .onDisappear {
            saveSettings()
        }
        .sheet(isPresented: $showingTestInstructions) {
            TestInstructionsView(
                port: port,
                useToken: !apiToken.isEmpty,
                allowNetworkAccess: allowNetworkAccess
            )
        }
    }
    
    private func loadSettings() {
        port = String(UserDefaults.standard.integer(forKey: "APIServerPort"))
        if port == "0" || port.isEmpty {
            port = "5000"
        }
        
        allowNetworkAccess = UserDefaults.standard.bool(forKey: "APIServerAllowNetworkAccess")
        autoStartAPI = UserDefaults.standard.bool(forKey: "APIServerAutoStart")
        
        if let token = UserDefaults.standard.string(forKey: "APIServerToken") {
            apiToken = token
        }
    }
    
    private func saveSettings() {
        if let portNumber = Int(port), portNumber > 0, portNumber <= 65535 {
            UserDefaults.standard.set(portNumber, forKey: "APIServerPort")
            apiServer.port = portNumber
        }
        
        UserDefaults.standard.set(allowNetworkAccess, forKey: "APIServerAllowNetworkAccess")
        UserDefaults.standard.set(apiToken, forKey: "APIServerToken")
    }
}

struct TestInstructionsView: View {
    let port: String
    let useToken: Bool
    let allowNetworkAccess: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Testing the API")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    GroupBox {
                        Text("Basic Test with curl")
                            .font(.headline)
                            .padding(.bottom, 4)
                        
                        let baseURL = allowNetworkAccess ? 
                            "YOUR_IP:\(port)" : 
                            "localhost:\(port)"
                        
                        let curlCommand = useToken ?
                            """
                            curl -X POST http://\(baseURL)/api/transcribe \\
                              -H "Authorization: Bearer YOUR_TOKEN" \\
                              -F "file=@audio.wav"
                            """ :
                            """
                            curl -X POST http://\(baseURL)/api/transcribe \\
                              -F "file=@audio.wav"
                            """
                        
                        Text(curlCommand)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                            .textSelection(.enabled)
                    }
                    
                    GroupBox {
                        Text("Health Check")
                            .font(.headline)
                            .padding(.bottom, 4)
                        
                        let healthCommand = "curl http://\(allowNetworkAccess ? "YOUR_IP" : "localhost"):\(port)/health"
                        
                        Text(healthCommand)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                            .textSelection(.enabled)
                    }
                    
                    GroupBox {
                        Text("Python Example")
                            .font(.headline)
                            .padding(.bottom, 4)
                        
                        let pythonCode = """
                        import requests
                        
                        url = "http://\(allowNetworkAccess ? "YOUR_IP" : "localhost"):\(port)/api/transcribe"
                        \(useToken ? "headers = {'Authorization': 'Bearer YOUR_TOKEN'}" : "")
                        
                        with open('audio.wav', 'rb') as f:
                            files = {'file': f}
                            response = requests.post(url, files=files\(useToken ? ", headers=headers" : ""))
                        
                        print(response.json())
                        """
                        
                        Text(pythonCode)
                            .font(.system(.body, design: .monospaced))
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                            .textSelection(.enabled)
                    }
                    
                    if allowNetworkAccess {
                        GroupBox {
                            Label("Network Access Note", systemImage: "network")
                                .font(.headline)
                                .padding(.bottom, 4)
                            
                            Text("Replace YOUR_IP with your computer's actual IP address. You can find it in System Settings > Network.")
                                .font(.body)
                        }
                        .background(Color.blue.opacity(0.1))
                    }
                }
                .padding()
            }
            // navigationBarTitleDisplayMode is not available on macOS
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}