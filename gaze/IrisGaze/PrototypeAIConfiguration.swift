import Foundation

/// Provide OPENAI_API_KEY through the local Xcode scheme environment.
/// Credentials must not be committed or embedded in source.
enum PrototypeAIConfiguration {
    static let model = "gpt-6-luna"
    static var apiKey: String { ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "" }
}
