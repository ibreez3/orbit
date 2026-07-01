import Foundation

class OpenAIService: ObservableObject {
    @Published var isLoading = false
    @Published var streamingText: String = ""

    private var streamTask: Task<Void, Never>?

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        Task { @MainActor [weak self] in
            self?.isLoading = false
        }
    }

    private var agentTask: Task<Void, Never>?

    func cancelAgent() {
        agentTask?.cancel()
        agentTask = nil
        streamTask?.cancel()
        streamTask = nil
        Task { @MainActor [weak self] in
            self?.isLoading = false
        }
    }

    // MARK: - Agent Loop (single-shot: call AI → extract ```execute → callback)

    func runAgent(
        messages: [AIChatMessage],
        systemPrompt: String,
        config: AIConfig,
        onToken: @escaping (String) -> Void,
        onCommands: @escaping ([String]) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        cancelAgent()

        agentTask = Task { [weak self] in
            guard let self = self else { return }
            await MainActor.run {
                self.isLoading = true
            }
            defer {
                Task { @MainActor [weak self] in
                    self?.isLoading = false
                }
            }

            // Build API messages
            var apiMessages: [[String: String]] = []
            apiMessages.append(["role": "system", "content": systemPrompt])
            let recent = Array(messages.suffix(30))
            for msg in recent {
                apiMessages.append(["role": msg.role, "content": msg.content])
            }

            let content = await self.callAndCollect(
                messages: apiMessages, config: config, onToken: onToken)
            if Task.isCancelled { return }

            if let error = content.error {
                await MainActor.run {
                    onComplete(.failure(error))
                }
                return
            }

            let fullContent = content.text ?? ""
            let commands = self.extractExecutes(from: fullContent)

            if commands.isEmpty {
                await MainActor.run {
                    onComplete(.success(fullContent))
                }
            } else {
                // Notify caller about commands, caller re-enters after execution
                await MainActor.run {
                    onCommands(commands)
                }
            }
        }
    }

    /// Extract ```execute ... ``` blocks from AI response
    func extractExecutes(from content: String) -> [String] {
        let pattern = "```execute\\s*\\n([\\s\\S]*?)\\n```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        return matches.compactMap { match in
            if let range = Range(match.range(at: 1), in: content) {
                return String(content[range]).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    // MARK: - Internal: call AI API and collect streaming response

    private struct AgentCallResult {
        let text: String?
        let error: Error?
    }

    private func callAndCollect(
        messages: [[String: String]],
        config: AIConfig,
        onToken: @escaping (String) -> Void
    ) async -> AgentCallResult {
        let endpoint = config.endpoint.hasSuffix("/v1")
            ? config.endpoint + "/chat/completions"
            : config.endpoint + "/v1/chat/completions"

        guard let url = URL(string: endpoint) else {
            return AgentCallResult(text: nil, error: NSError(domain: "AIService", code: -1))
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 2000,
            "stream": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return AgentCallResult(text: nil, error: NSError(domain: "AIService", code: -2))
        }

        var fullContent = ""
        var lineData = Data()
        var tokenBatcher = TokenBatcher()

        do {
            for try await byte in bytes {
                if Task.isCancelled { break }
                lineData.append(byte)
                if byte == UInt8(ascii: "\n") {
                    guard let line = String(data: lineData, encoding: .utf8) else {
                        lineData.removeAll(keepingCapacity: true)
                        continue
                    }
                    lineData.removeAll(keepingCapacity: true)

                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("data:") else { continue }
                    let dataStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if dataStr == "[DONE]" { break }

                    guard let data = dataStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]] else { continue }

                    for choice in choices {
                        if let delta = choice["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            fullContent += content
                            await tokenBatcher.append(content, onToken: onToken)
                        }
                    }
                }
            }
        } catch {
            if fullContent.isEmpty {
                return AgentCallResult(text: nil, error: error)
            }
        }

        await tokenBatcher.flush(onToken: onToken)
        return AgentCallResult(text: fullContent, error: nil)
    }

    // MARK: - Streaming (primary)

    func streamMessage(
        messages: [AIChatMessage],
        systemPrompt: String,
        config: AIConfig,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        let endpoint = config.endpoint.hasSuffix("/v1")
            ? config.endpoint + "/chat/completions"
            : config.endpoint + "/v1/chat/completions"

        guard let url = URL(string: endpoint) else {
            DispatchQueue.main.async { [weak self] in
                self?.isLoading = false
                onComplete(.failure(NSError(domain: "AIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])))
            }
            return
        }

        var msgs: [[String: String]] = []
        msgs.append(["role": "system", "content": systemPrompt])
        let recent = Array(messages.suffix(20))
        for msg in recent {
            msgs.append(["role": msg.role, "content": msg.content])
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": msgs,
            "temperature": 0.3,
            "max_tokens": 2000,
            "stream": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.isLoading = false
                onComplete(.failure(error))
            }
            return
        }

        streamTask = Task { [weak self] in
            guard let self = self else { return }
            await MainActor.run {
                self.isLoading = true
            }
            defer {
                Task { @MainActor [weak self] in
                    self?.isLoading = false
                }
            }

            let bytes: URLSession.AsyncBytes
            let response: URLResponse

            do {
                (bytes, response) = try await URLSession.shared.bytes(for: request)
            } catch {
                // Fall back to non-streaming single-shot
                self.sendOnce(messages: messages, systemPrompt: systemPrompt, config: config, completion: onComplete)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run {
                    onComplete(.failure(NSError(domain: "AIService", code: -2, userInfo: [NSLocalizedDescriptionKey: "无效响应"])))
                }
                return
            }

            if httpResponse.statusCode != 200 {
                let errorBody = await self.collectString(from: bytes, maxLength: 2000)
                let message: String
                if httpResponse.statusCode == 401 {
                    message = "API Key 无效"
                } else if !errorBody.isEmpty {
                    message = errorBody
                } else {
                    message = "HTTP \(httpResponse.statusCode)"
                }
                await MainActor.run {
                    onComplete(.failure(NSError(domain: "AIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])))
                }
                return
            }

            let contentType = (httpResponse.allHeaderFields["Content-Type"] as? String) ?? ""

            if contentType.contains("text/event-stream") || contentType.contains("application/x-ndjson") {
                await self.parseSSE(bytes: bytes, onToken: onToken, onComplete: onComplete)
            } else {
                await self.parseBufferedJSON(bytes: bytes, onComplete: onComplete)
            }
        }
    }

    // MARK: - SSE Parser

    private func parseSSE(
        bytes: URLSession.AsyncBytes,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) async {
        var fullContent = ""
        var lineData = Data()
        var tokenBatcher = TokenBatcher()

        do {
            for try await byte in bytes {
                if Task.isCancelled { break }

                lineData.append(byte)

                if byte == UInt8(ascii: "\n") {
                    guard let line = String(data: lineData, encoding: .utf8) else {
                        lineData.removeAll(keepingCapacity: true)
                        continue
                    }
                    lineData.removeAll(keepingCapacity: true)

                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("data:") else { continue }
                    let dataStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)

                    if dataStr == "[DONE]" {
                        await tokenBatcher.flush(onToken: onToken)
                        let completedContent = fullContent
                        await MainActor.run {
                            onComplete(.success(completedContent))
                        }
                        return
                    }

                    guard let data = dataStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]] else {
                        continue
                    }

                    for choice in choices {
                        if let delta = choice["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            fullContent += content
                            await tokenBatcher.append(content, onToken: onToken)
                        }
                    }
                }
            }

            await tokenBatcher.flush(onToken: onToken)
            let completedContent = fullContent
            await MainActor.run {
                onComplete(.success(completedContent))
            }
        } catch {
            await tokenBatcher.flush(onToken: onToken)
            if !fullContent.isEmpty {
                let completedContent = fullContent
                await MainActor.run {
                    onComplete(.success(completedContent))
                }
            } else {
                await MainActor.run {
                    onComplete(.failure(error))
                }
            }
        }
    }

    // MARK: - Buffered JSON fallback

    private func parseBufferedJSON(
        bytes: URLSession.AsyncBytes,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) async {
        var data = Data()
        do {
            for try await byte in bytes {
                if Task.isCancelled { break }
                data.append(byte)
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                await MainActor.run {
                    onComplete(.failure(NSError(domain: "AIService", code: -3, userInfo: [NSLocalizedDescriptionKey: "解析响应失败"])))
                }
                return
            }
            await MainActor.run {
                onComplete(.success(content))
            }
        } catch {
            await MainActor.run {
                onComplete(.failure(error))
            }
        }
    }

    // MARK: - Single-shot fallback

    private func sendOnce(
        messages: [AIChatMessage],
        systemPrompt: String,
        config: AIConfig,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let endpoint = config.endpoint.hasSuffix("/v1")
            ? config.endpoint + "/chat/completions"
            : config.endpoint + "/v1/chat/completions"

        guard let url = URL(string: endpoint) else {
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "AIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])))
            }
            return
        }

        var msgs: [[String: String]] = []
        msgs.append(["role": "system", "content": systemPrompt])
        let recent = Array(messages.suffix(20))
        for msg in recent {
            msgs.append(["role": msg.role, "content": msg.content])
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": msgs,
            "temperature": 0.3,
            "max_tokens": 2000,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let data = data else {
                    completion(.failure(NSError(domain: "AIService", code: -2, userInfo: [NSLocalizedDescriptionKey: "空响应"])))
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 401 {
                        completion(.failure(NSError(domain: "AIService", code: 401, userInfo: [NSLocalizedDescriptionKey: "API Key 无效"])))
                        return
                    }
                    if httpResponse.statusCode != 200 {
                        if let body = String(data: data, encoding: .utf8) {
                            completion(.failure(NSError(domain: "AIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: body])))
                        } else {
                            completion(.failure(NSError(domain: "AIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])))
                        }
                        return
                    }
                }

                do {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let first = choices.first,
                          let message = first["message"] as? [String: Any],
                          let content = message["content"] as? String else {
                        completion(.failure(NSError(domain: "AIService", code: -3, userInfo: [NSLocalizedDescriptionKey: "解析响应失败"])))
                        return
                    }
                    completion(.success(content))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    // MARK: - Helpers

    private func collectString(from bytes: URLSession.AsyncBytes, maxLength: Int) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                if data.count >= maxLength { break }
                data.append(byte)
            }
        } catch {
            // ignore read errors
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private struct TokenBatcher {
        private static let flushIntervalNanos: UInt64 = 75_000_000
        private static let flushCharacterCount = 96

        private var buffer = ""
        private var lastFlushNanos = DispatchTime.now().uptimeNanoseconds

        mutating func append(_ token: String, onToken: @escaping (String) -> Void) async {
            buffer += token

            let now = DispatchTime.now().uptimeNanoseconds
            if buffer.count >= Self.flushCharacterCount || now - lastFlushNanos >= Self.flushIntervalNanos {
                await flush(onToken: onToken, now: now)
            }
        }

        mutating func flush(onToken: @escaping (String) -> Void, now: UInt64 = DispatchTime.now().uptimeNanoseconds) async {
            guard !buffer.isEmpty else { return }

            let chunk = buffer
            buffer.removeAll(keepingCapacity: true)
            lastFlushNanos = now

            await MainActor.run {
                onToken(chunk)
            }
        }
    }
}

struct AICommandSuggestion: Decodable {
    let command: String
    let explanation: String
}
