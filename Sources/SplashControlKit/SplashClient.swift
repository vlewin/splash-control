import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking  // Linux: URLSession lives here, not in Foundation.
#endif

/// Loopback-only client for the splash HTTP server. Never talks to anything else.
public final class SplashClient {
  private let session: URLSession
  private let genSession: URLSession

  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 4
    config.timeoutIntervalForResource = 10
    self.session = URLSession(configuration: config)

    // A 512-token completion at ~25 tok/s is ~20 s, and a slow one can run
    // much longer; the poll timeouts would abort it mid-stream.
    let gen = URLSessionConfiguration.ephemeral
    gen.timeoutIntervalForRequest = 180
    // Must exceed the largest per-request timeout the bench asks for (1800 s),
    // or the resource cap fires first and the per-request value is irrelevant.
    gen.timeoutIntervalForResource = 1800
    self.genSession = URLSession(configuration: gen)
  }

  private func base(_ port: Int) -> String {
    "http://127.0.0.1:\(port)"
  }

  /// Liveness only. Readiness is not a separate request any more: a 200 from
  /// `/status` carries `ready` in the payload, so polling `/ready` as well
  /// bought nothing and cost one round trip per tick.
  public func health(port: Int) async -> Bool {
    guard let url = URL(string: base(port) + "/health") else { return false }
    do {
      let (_, response) = try await session.data(from: url)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }

  public func status(port: Int) async throws -> StatusDTO {
    guard let url = URL(string: base(port) + "/status") else {
      throw SplashError.notReachable
    }
    let (data, response) = try await session.data(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw SplashError.badStatus
    }
    return try JSONDecoder().decode(StatusDTO.self, from: data)
  }

  public struct Completion: Decodable {
    public struct Usage: Decodable {
      /// `completion_tokens` counts reasoning **and** answer, so a
      /// "list 3 libraries" prompt can report 256 tokens of output while
      /// the answer is empty. Both parts are needed to read that.
      public struct Details: Decodable {
        public let reasoningTokens: Int?
        enum CodingKeys: String, CodingKey {
          case reasoningTokens = "reasoning_tokens"
        }
      }
      public let promptTokens: Int?
      public let completionTokens: Int?
      public let completionTokensDetails: Details?
      enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case completionTokensDetails = "completion_tokens_details"
      }
    }
    public struct Timings: Decodable {
      public let promptN: Int?
      public let promptMs: Double?
      public let promptPerSecond: Double?
      public let predictedN: Int?
      public let predictedMs: Double?
      public let predictedPerSecond: Double?
      public let cacheN: Int?
      enum CodingKeys: String, CodingKey {
        case promptN = "prompt_n"
        case promptMs = "prompt_ms"
        case promptPerSecond = "prompt_per_second"
        case predictedN = "predicted_n"
        case predictedMs = "predicted_ms"
        case predictedPerSecond = "predicted_per_second"
        case cacheN = "cache_n"
      }
    }
    public struct Choice: Decodable {
      public struct Msg: Decodable {
        public let content: String?
        public let reasoningContent: String?
        enum CodingKeys: String, CodingKey {
          case content
          case reasoningContent = "reasoning_content"
        }
      }
      /// `stop` = the model finished; `length` = it was cut off by
      /// max_tokens. Without this a truncated run is indistinguishable from
      /// a concise one — the bench could only infer it from the token count.
      public let finishReason: String?
      public let message: Msg?
      enum CodingKeys: String, CodingKey {
        case finishReason = "finish_reason"
        case message
      }
    }
    public let usage: Usage?
    public let timings: Timings?
    public let choices: [Choice]?
    public let error: SplashServerError?
  }

  public struct SplashServerError: Decodable {
    public let message: String?
  }

  /// One non-streaming chat completion. `body` must already be JSON-encoded.
  /// Non-streaming is deliberate: the reply carries `timings`, which is
  /// everything the bench reports, so there is no need to parse SSE.
  public func complete(port: Int, body: Data, timeout: TimeInterval = 180) async throws
    -> Completion
  {
    guard let url = URL(string: base(port) + "/v1/chat/completions") else {
      throw SplashError.notReachable
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Applied per request, overriding the session's 180 s default. Without this
    // line `timeout` is dead and every long prompt dies at 180 s — which is
    // what made 64K fail on 2 of 3 models while reporting a 17-minute limit.
    req.timeoutInterval = timeout
    let (data, response) = try await genSession.data(for: req)
    let http = response as? HTTPURLResponse
    guard http?.statusCode == 200 else {
      // 400 is how a model without vision rejects an image; the caller
      // matches the message to record a skip rather than a failure.
      let msg = (try? JSONDecoder().decode(Completion.self, from: data))?.error?.message
      throw SplashError.completionFailed(status: http?.statusCode ?? 0, message: msg)
    }
    return try JSONDecoder().decode(Completion.self, from: data)
  }

  public enum SplashError: LocalizedError {
    case notReachable
    case badStatus
    case completionFailed(status: Int, message: String?)
    public var errorDescription: String? {
      switch self {
      case .notReachable: return "No reachable splash endpoint"
      case .badStatus: return "splash returned an error status"
      case .completionFailed(let status, let message):
        return message.map { "\(status): \($0)" } ?? "completion failed (HTTP \(status))"
      }
    }
  }
}
