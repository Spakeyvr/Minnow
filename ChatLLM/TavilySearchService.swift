//
//  TavilySearchService.swift
//  ChatLLM
//
//  Created by Nevio on 10/26/25.
//

import CryptoKit
import Foundation

struct TavilySearchResult: Decodable, Identifiable, Sendable {
    var id = UUID()
    let title: String
    let url: String
    let content: String
    let score: Double?
    let publishedDate: String?
    let favicon: String?

    enum CodingKeys: String, CodingKey {
        case title, url, content, score, favicon
        case publishedDate = "published_date"
    }

    nonisolated init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        score = try container.decodeIfPresent(Double.self, forKey: .score)
        publishedDate = try container.decodeIfPresent(String.self, forKey: .publishedDate)
        favicon = try container.decodeIfPresent(String.self, forKey: .favicon)
    }
}

struct TavilySearchResponse: Decodable, Sendable {
    let query: String
    let results: [TavilySearchResult]
    let responseTime: Double?
    let requestID: String?
    let creditsUsed: Int?

    private enum CodingKeys: String, CodingKey {
        case query, results, usage
        case responseTime = "response_time"
        case requestID = "request_id"
    }

    private struct Usage: Decodable {
        let credits: Int?
    }

    nonisolated init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decode(String.self, forKey: .query)
        results = try container.decode([TavilySearchResult].self, forKey: .results)
        if let numericResponseTime = try? container.decode(Double.self, forKey: .responseTime) {
            responseTime = numericResponseTime
        } else if let stringResponseTime = try? container.decode(String.self, forKey: .responseTime) {
            responseTime = Double(stringResponseTime)
        } else {
            responseTime = nil
        }
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        creditsUsed = try container.decodeIfPresent(Usage.self, forKey: .usage)?.credits
    }
}

private struct TavilyAPIErrorResponse: Decodable, Sendable {
    let detail: String?
    let message: String?
    let error: String?
    let nestedError: NestedError?

    enum CodingKeys: String, CodingKey {
        case detail, message, error
    }

    struct NestedError: Decodable, Sendable {
        let message: String?
        let code: String?
    }

    /// Tavily documents `{"detail": {"error": "..."}}`; older responses used a
    /// plain string. Each field is optional so one odd shape never hides the rest.
    private struct NestedDetail: Decodable, Sendable {
        let error: String?
        let message: String?
    }

    nonisolated init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decodeIfPresent(String.self, forKey: .detail) {
            detail = text
        } else if let nested = try? container.decodeIfPresent(NestedDetail.self, forKey: .detail) {
            detail = nested.error ?? nested.message
        } else {
            detail = nil
        }
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        nestedError = try? container.decodeIfPresent(NestedError.self, forKey: .error)
    }
}

enum TavilySearchError: LocalizedError {
    case invalidQuery
    case invalidAPIKey
    case rateLimited
    case usageLimitReached
    case networkError(Error)
    case noResults
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidQuery: String(localized: "Enter a search query under 400 characters.", bundle: .appLocalized)
        case .invalidAPIKey: String(localized: "The Tavily API key is missing or invalid.", bundle: .appLocalized)
        case .rateLimited: String(localized: "Tavily is receiving too many searches right now. Try again in a moment.", bundle: .appLocalized)
        case .usageLimitReached: String(localized: "Your Tavily plan has run out of search credits. Check your plan on tavily.com.", bundle: .appLocalized)
        case .networkError(let error): String(localized: "Web search failed: \(error.localizedDescription)", bundle: .appLocalized)
        case .noResults: String(localized: "No relevant web results were found.", bundle: .appLocalized)
        case .decodingError: String(localized: "Tavily returned a response ChatLLM could not read.", bundle: .appLocalized)
        }
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// Search results shared by every `TavilySearchService` that uses the same
/// API key, so recreating the service (new chat, key notification) keeps them.
actor TavilySearchResultCache {
    static let shared = TavilySearchResultCache()

    private struct Entry {
        let value: WebSearchResponse
        let storedAt: Date
        let lifetime: TimeInterval
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]

    init(capacity: Int = 32) {
        self.capacity = max(capacity, 1)
    }

    func value(for key: String, now: Date = Date()) -> WebSearchResponse? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) <= entry.lifetime else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func store(_ value: WebSearchResponse, for key: String, lifetime: TimeInterval, now: Date = Date()) {
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(value: value, storedAt: now, lifetime: lifetime)
    }
}

actor TavilySearchService: WebSearchProviding {
    nonisolated static let maximumQueryLength = 400
    nonisolated private static let liveCacheTTL: TimeInterval = 60
    nonisolated private static let standardCacheTTL: TimeInterval = 600
    nonisolated private static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
    /// 432: plan limit exceeded; 433: pay-as-you-go limit exceeded.
    nonisolated private static let usageLimitStatusCodes: Set<Int> = [432, 433]
    // Keep search + retry inside ChatViewModel's 60 s web-search stream timeout.
    nonisolated private static let maximumRetryAfterSeconds: Double = 10

    private let apiKey: String
    private let baseURL = URL(string: "https://api.tavily.com/search")!
    private let usageURL = URL(string: "https://api.tavily.com/usage")!
    private let session: URLSession
    private let cache: TavilySearchResultCache
    /// Scopes shared cache entries to this key without keeping the key text in them.
    private let cacheNamespace: String

    /// Services on the shared URLSession share one result cache. A custom
    /// session (tests, mocks) gets a private cache unless one is passed in.
    init(apiKey: String, session: URLSession = .shared, cache: TavilySearchResultCache? = nil) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw TavilySearchError.invalidAPIKey }
        self.apiKey = trimmedKey
        self.session = session
        self.cache = cache ?? (session === URLSession.shared ? .shared : TavilySearchResultCache())
        self.cacheNamespace = SHA256.hash(data: Data(trimmedKey.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func search(query: String, maxResults: Int = 4, searchDepth: String? = nil) async throws -> WebSearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, trimmedQuery.count <= Self.maximumQueryLength else {
            throw TavilySearchError.invalidQuery
        }

        let resultLimit = min(max(maxResults, 1), 5)
        let resolvedDepth = Self.validSearchDepth(searchDepth)
        let cacheKey = cacheNamespace + "|" + Self.makeCacheKey(query: trimmedQuery, maxResults: resultLimit, searchDepth: resolvedDepth)
        if let cached = await cache.value(for: cacheKey) { return cached }

        var request = URLRequest(url: baseURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "query": trimmedQuery,
            "max_results": resultLimit,
            "include_answer": false,
            "include_raw_content": false,
            "include_favicon": true,
            "include_usage": true,
            "auto_parameters": true
        ]
        if let resolvedDepth { body["search_depth"] = resolvedDepth }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await perform(request)
        try validate(response: response, data: data)

        let decoded: TavilySearchResponse
        do {
            decoded = try JSONDecoder().decode(TavilySearchResponse.self, from: data)
        } catch {
            throw TavilySearchError.decodingError(error)
        }

        let sources = Self.makeSources(from: decoded.results, limit: resultLimit)
        guard !sources.isEmpty else { throw TavilySearchError.noResults }

        let result = WebSearchResponse(
            query: decoded.query.isEmpty ? trimmedQuery : decoded.query,
            sources: sources,
            responseTimeSeconds: decoded.responseTime,
            requestID: decoded.requestID,
            creditsUsed: decoded.creditsUsed
        )
        await cache.store(
            result,
            for: cacheKey,
            lifetime: Self.isLiveQuery(trimmedQuery) ? Self.liveCacheTTL : Self.standardCacheTTL
        )
        return result
    }

    func validateAPIKey() async throws {
        var request = URLRequest(url: usageURL, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request, retryCount: 0)
        try validate(response: response, data: data)
    }

    private func perform(_ request: URLRequest, retryCount: Int = 1) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                let result = try await session.data(for: request)
                if let response = result.1 as? HTTPURLResponse,
                   Self.retryableStatusCodes.contains(response.statusCode),
                   attempt < retryCount {
                    attempt += 1
                    try await Task.sleep(for: Self.retryDelay(for: response, attempt: attempt))
                    continue
                }
                return result
            } catch {
                // URLSession reports task cancellation as URLError(.cancelled).
                if Task.isCancelled || TavilySearchError.isCancellation(error) {
                    throw CancellationError()
                }
                if attempt < retryCount, (error as? URLError)?.isTransientConnectivityFailure == true {
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(250 * attempt))
                    continue
                }
                throw TavilySearchError.networkError(error)
            }
        }
    }

    nonisolated static func retryDelay(for response: HTTPURLResponse, attempt: Int) -> Duration {
        let fallback = Duration.milliseconds(250 * max(attempt, 1))
        guard response.statusCode == 429,
              let header = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(header.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds >= 0 else {
            return fallback
        }

        let boundedSeconds = min(seconds, maximumRetryAfterSeconds)
        return .milliseconds(Int((boundedSeconds * 1_000).rounded(.up)))
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TavilySearchError.networkError(
                NSError(domain: "Tavily", code: -1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Invalid server response", bundle: .appLocalized)])
            )
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw TavilySearchError.invalidAPIKey
            }
            // perform(_:) already retried, honoring Retry-After.
            if httpResponse.statusCode == 429 {
                throw TavilySearchError.rateLimited
            }
            if Self.usageLimitStatusCodes.contains(httpResponse.statusCode) {
                throw TavilySearchError.usageLimitReached
            }
            let message = parseErrorMessage(from: data)
                ?? String(localized: "Tavily returned status \(httpResponse.statusCode).", bundle: .appLocalized)
            throw TavilySearchError.networkError(
                NSError(domain: "Tavily", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            )
        }
    }

    nonisolated private static func makeSources(from results: [TavilySearchResult], limit: Int) -> [WebSearchSource] {
        var seenURLs: Set<String> = []
        let ranked = results.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        let relevant = ranked.filter { ($0.score ?? 1) >= 0.25 }
        let candidates = relevant.isEmpty ? ranked : relevant

        return candidates.compactMap { result in
            let source = WebSearchSource(
                title: compactWhitespace(result.title) ?? result.url,
                url: result.url,
                snippet: compactWhitespace(result.content) ?? "",
                score: result.score,
                publishedDate: compactWhitespace(result.publishedDate),
                faviconURL: result.favicon
            )
            guard source.resolvedURL != nil,
                  seenURLs.insert(normalizedURL(result.url)).inserted else { return nil }
            return source
        }
        .prefix(limit)
        .map { $0 }
    }

    nonisolated private static func normalizedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value.lowercased() }
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return (components.string ?? value).lowercased()
    }

    nonisolated private static func compactWhitespace(_ text: String?) -> String? {
        guard let text else { return nil }
        let compact = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return compact.isEmpty ? nil : compact
    }

    nonisolated private static func validSearchDepth(_ value: String?) -> String? {
        guard let value = value?.lowercased() else { return nil }
        return ["basic", "advanced", "fast", "ultra-fast"].contains(value) ? value : nil
    }

    nonisolated private static func makeCacheKey(query: String, maxResults: Int, searchDepth: String?) -> String {
        let normalized = query.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return [normalized, String(maxResults), searchDepth ?? "auto"].joined(separator: "|")
    }

    /// Models often search in the user's language, so this covers every interface language.
    nonisolated private static let liveQueryWords: Set<String> = [
        "today", "tonight", "current", "currently", "latest", "live", "breaking",
        "price", "prices", "score", "scores", "weather", "news",
        "heute", "aktuell", "aktuelle", "aktuellen", "neueste", "neuesten", "preis", "preise",
        "kurs", "spielstand", "ergebnis", "ergebnisse", "wetter", "nachrichten", "jetzt",
        "hoy", "actual", "último", "última", "precio", "precios", "marcador", "resultado",
        "resultados", "clima", "noticias", "ahora"
    ]
    nonisolated private static let liveQueryPhrases: [[String]] = [
        ["this", "week"], ["right", "now"]
    ]

    /// Matches whole words only, so "deliver" or "Diskurs" do not count as live.
    nonisolated static func isLiveQuery(_ query: String) -> Bool {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if words.contains(where: liveQueryWords.contains) {
            return true
        }
        return liveQueryPhrases.contains { phrase in
            words.count >= phrase.count && (0...(words.count - phrase.count)).contains { start in
                Array(words[start..<(start + phrase.count)]) == phrase
            }
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let decoded = try? JSONDecoder().decode(TavilyAPIErrorResponse.self, from: data) {
            return decoded.detail ?? decoded.message ?? decoded.error
                ?? decoded.nestedError?.message ?? decoded.nestedError?.code
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
