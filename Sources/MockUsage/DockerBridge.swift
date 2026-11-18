import Foundation
#if SWIFT_PACKAGE
import UsageCore
#endif

enum BridgeError: LocalizedError {
    case unavailable, timeout, invalidOutput, failed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Docker CLI not found. Set its path in Settings."
        case .timeout: return "Container request timed out. Check Docker and network access."
        case .invalidOutput: return "Container returned an unsupported response."
        case .failed: return "Docker could not run the collector. Check the container name, Docker context and Python 3."
        }
    }
}

struct ResetDiagnosticEvent: Codable {
    var stage: String
    var outcome: String?
    var seconds: Int?
    var httpStatus: Int?
    var reason: String?
}

struct ResetResponse: Decodable {
    var diagnostics: [ResetDiagnosticEvent]?
    var result: String?
    var error: String?
    var message: String?
}

enum DockerBridge {
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let protocolVersion = envelope["protocolVersion"] as? Int, protocolVersion == 1 else { throw BridgeError.invalidOutput }
        return try JSONDecoder().decode(type, from: data)
    }

    static var collectorURL: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "collector", withExtension: "py")
        #else
        return Bundle.main.url(forResource: "collector", withExtension: "py")
        #endif
    }

    static func collect(source: Source, configuration: Configuration) async throws -> CollectorResponse {
        guard source.isValid, let url = collectorURL else { throw BridgeError.invalidOutput }
        let input = try Data(contentsOf: url)
        let args = ["--context", configuration.dockerContext, "exec", "-i", source.container,
                    "python3", "-", source.provider.rawValue]
        let data = try await execute(path: configuration.dockerPath, arguments: args, input: input)
        return try decode(CollectorResponse.self, from: data)
    }

    static func redeem(source: Source, configuration: Configuration, snapshot: UsageSnapshot, grant: ResetGrant) async throws -> ResetResponse {
        guard source.isValid, let url = collectorURL,
              let runtime = snapshot.runtime, runtime.resetSupported, runtime.protocolVersion == 1,
              let accountKey = snapshot.accountKey, let grantID = grant.providerGrantID, let binding = grant.confirmationBinding else { throw BridgeError.invalidOutput }
        let intent: [String: Any] = ["accountKey": accountKey, "grantID": grantID,
                                   "binding": binding, "runtimeVersion": runtime.providerVersion, "adapterID": runtime.adapterID, "confirmedAt": Date().timeIntervalSince1970]
        let encoded = try JSONSerialization.data(withJSONObject: intent).base64EncodedString()
        let args = ["--context", configuration.dockerContext, "exec", "-i", source.container,
                    "python3", "-", source.provider.rawValue, "--confirmed-reset", encoded]
        let data = try await execute(path: configuration.dockerPath, arguments: args, input: Data(contentsOf: url), timeout: 150)
        return try decode(ResetResponse.self, from: data)
    }

    static func models(source: Source, configuration: Configuration) async throws -> ModelCatalogResponse {
        guard source.isValid, let url = collectorURL else { throw BridgeError.invalidOutput }
        var version = "unavailable"
        if source.provider == .gptmock {
            let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/Codex.app/Contents/Resources/codex"]
            for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
                if let output = try? await execute(path: path, arguments: ["--version"], input: nil),
                   let match = String(decoding: output, as: UTF8.self).range(of: #"[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.\-]*"#, options: .regularExpression) {
                    version = String(String(decoding: output, as: UTF8.self)[match]); break
                }
            }
        }
        let args = ["--context", configuration.dockerContext, "exec", "-i", source.container,
                    "python3", "-", source.provider.rawValue, "--models", version]
        let data = try await execute(path: configuration.dockerPath, arguments: args, input: Data(contentsOf: url))
        return try decode(ModelCatalogResponse.self, from: data)
    }

    static func containers(configuration: Configuration) async throws -> [String] {
        let data = try await execute(path: configuration.dockerPath,
            arguments: ["--context", configuration.dockerContext, "ps", "-a", "--format", "{{.Names}}"], input: nil)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
    }

    // Pipes are drained to temporary files, avoiding deadlocks on stderr or stdout.
    // No shell interpolation, raw Docker errors, or credential-bearing output is logged.
    static func execute(path: String, arguments: [String], input: Data?, timeout: TimeInterval = 65) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: path) else { throw BridgeError.unavailable }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let outputURL = directory.appendingPathComponent("output")
            let inputURL = directory.appendingPathComponent("input")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try (input ?? Data()).write(to: inputURL)
            let output = try FileHandle(forWritingTo: outputURL)
            let stdin = try FileHandle(forReadingFrom: inputURL)
            defer { try? output.close(); try? stdin.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = stdin
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { try await Task.sleep(nanoseconds: 50_000_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw BridgeError.timeout
            }
            guard process.terminationStatus == 0 else { throw BridgeError.failed }
            let data = try Data(contentsOf: outputURL)
            guard data.count <= 2_000_000 else { throw BridgeError.invalidOutput }
            return data
        }.value
    }
}
