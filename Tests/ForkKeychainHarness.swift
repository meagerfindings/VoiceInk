import Foundation
import Security

// Shadow Security calls in this test executable; never access the user's Keychain.
private var capturedQuery: [String: Any] = [:]
private var capturedAttributes: [String: Any] = [:]
private var readStatus: OSStatus = errSecItemNotFound
private var readValue: Data?
private var updateStatuses: [OSStatus] = []
private var addStatus: OSStatus = errSecSuccess
private var addCalls = 0

func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    capturedQuery = query as! [String: Any]
    result?.pointee = readValue as CFTypeRef?
    return readStatus
}

func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    capturedQuery = query as! [String: Any]
    capturedAttributes = attributes as! [String: Any]
    return updateStatuses.removeFirst()
}

func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    capturedQuery = attributes as! [String: Any]
    addCalls += 1
    return addStatus
}

func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    fatalError("Saving must not delete an existing credential")
}

@main
struct ForkKeychainHarness {
    static func main() {
        let service = KeychainService.shared

        expect(service.getData(forKey: "fork-test") == nil, "missing credential remains missing")
        expect(
            capturedQuery[kSecAttrService as String] as? String == "com.prakashjoshipax.VoiceInk", "existing namespace")
        expect(capturedQuery[kSecUseDataProtectionKeychain as String] as? Bool == true, "Data Protection Keychain")
        expect(capturedQuery[kSecAttrSynchronizable as String] as? Bool == true, "syncable query preserved")
        expect(capturedQuery[kSecAttrAccount as String] as? String == "fork-test", "account preserved")

        _ = service.getData(forKey: "fork-test", syncable: false)
        expect(capturedQuery[kSecAttrSynchronizable as String] == nil, "non-syncable query does not opt into sync")

        readStatus = errSecSuccess
        readValue = Data("test-only-value".utf8)
        expect(service.getString(forKey: "fork-test") == "test-only-value", "existing credential returned")

        readStatus = errSecInteractionNotAllowed
        if case .unavailable(let status) = service.readData(forKey: "fork-test") {
            expect(status == errSecInteractionNotAllowed, "unavailable status retained")
        } else {
            fatalError("Unavailable Keychain must not be treated as missing")
        }

        updateStatuses = [errSecAuthFailed]
        expect(!service.save("replacement", forKey: "fork-test"), "failed update is reported")
        expect(addCalls == 0, "failed update must not add or delete")

        updateStatuses = [errSecSuccess]
        expect(
            service.save("replacement", forKey: "fork-test", accessibility: .afterFirstUnlockThisDeviceOnly),
            "existing item updated")
        expect(capturedAttributes[kSecValueData as String] as? Data == Data("replacement".utf8), "replacement data")
        expect(
            capturedAttributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "accessibility preserved")
        expect(addCalls == 0, "successful update does not recreate item")

        updateStatuses = [errSecItemNotFound]
        expect(service.save("new-value", forKey: "new-test-item"), "missing item added")
        expect(addCalls == 1, "one add for missing item")
        expect(capturedQuery[kSecValueData as String] as? Data == Data("new-value".utf8), "new data added")

        addStatus = errSecDuplicateItem
        updateStatuses = [errSecItemNotFound, errSecSuccess]
        expect(service.save("race-value", forKey: "race-test-item"), "concurrent insertion retried as update")
        expect(updateStatuses.isEmpty, "second update attempted")
        expect(
            capturedAttributes[kSecValueData as String] as? Data == Data("race-value".utf8), "retry uses intended data")

        print("Fork Keychain harness: all tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
    }
}
