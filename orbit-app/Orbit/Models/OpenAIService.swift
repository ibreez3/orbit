import Foundation

class OpenAIService: ObservableObject {
    @Published var isLoading = false

    func sendMessage(
        messages: [AIChatMessage],
        systemPrompt: String,
        config: AIConfig,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        isLoading = true

        let endpoint = config.endpoint.hasSuffix("/v1")
            ? config.endpoint + "/chat/completions"
            : config.endpoint + "/v1/chat/completions"

        guard let url = URL(string: endpoint) else {
            completion(.failure(NSError(domain: "AIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])))
            isLoading = false
            return
        }

        // Build message list
        var msgs: [[String: String]] = []
        msgs.append(["role": "system", "content": systemPrompt])

        // Limit context to last 20 messages to avoid token overflow
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
            completion(.failure(error))
            isLoading = false
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.isLoading = false }

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
        }.resume()
    }
}

struct AICommandSuggestion: Decodable {
    let command: String
    let explanation: String
}
