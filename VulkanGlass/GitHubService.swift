import Foundation

enum GitHubError: LocalizedError {
    case noToken
    case badInput
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "Sign in with GitHub CLI (gh auth login) or add a personal access token in Settings."
        case .badInput: return "Enter a GitHub URL or owner/repo."
        case .api(let message): return message
        }
    }
}

enum GitHubService {
    private static let api = "https://api.github.com"

    /// Fetches the authenticated user.
    static func user(token: String) async throws -> GitHubUser {
        let json = try await request("/user", token: token)
        guard let login = json["login"] as? String else { throw GitHubError.api("Unexpected user payload") }
        return GitHubUser(
            login: login,
            name: json["name"] as? String,
            avatarURL: json["avatar_url"] as? String ?? ""
        )
    }

    /// Lists repositories the token can access.
    static func repos(token: String) async throws -> [GitHubRepo] {
        let items = try await requestArray("/user/repos?per_page=100&sort=updated", token: token)
        return items.compactMap { item in
            guard let id = item["id"] as? Int,
                  let name = item["name"] as? String,
                  let full = item["full_name"] as? String,
                  let clone = item["clone_url"] as? String
            else { return nil }
            return GitHubRepo(
                id: id,
                name: name,
                fullName: full,
                description: item["description"] as? String,
                isPrivate: item["private"] as? Bool ?? false,
                cloneURL: clone,
                htmlURL: item["html_url"] as? String ?? ""
            )
        }
    }

    /// Creates a GitHub repository for the authenticated user.
    static func createRepo(name: String, isPrivate: Bool, token: String) async throws -> GitHubRepo {
        let body: [String: Any] = [
            "name": name,
            "private": isPrivate,
            "auto_init": false,
            "description": "Vulkan Glass vault"
        ]
        let item = try await request("/user/repos", token: token, method: "POST", body: body)
        guard let id = item["id"] as? Int,
              let repoName = item["name"] as? String,
              let full = item["full_name"] as? String,
              let clone = item["clone_url"] as? String
        else { throw GitHubError.api("Unexpected create payload") }
        return GitHubRepo(
            id: id,
            name: repoName,
            fullName: full,
            description: item["description"] as? String,
            isPrivate: item["private"] as? Bool ?? isPrivate,
            cloneURL: clone,
            htmlURL: item["html_url"] as? String ?? ""
        )
    }

    /// Parses owner/repo from a URL or shorthand.
    static func parseRepo(_ input: String) -> (owner: String, repo: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String]

        if trimmed.hasPrefix("git@github.com:") {
            parts = String(trimmed.dropFirst("git@github.com:".count)).split(separator: "/").map(String.init)
        } else if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  components.host?.lowercased() == "github.com"
            else { return nil }
            parts = components.path.split(separator: "/").map(String.init)
        } else {
            parts = trimmed.split(separator: "/").map(String.init)
        }

        guard parts.count == 2 else { return nil }
        let owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard validOwner(owner), validRepo(repo) else { return nil }
        return (owner, repo)
    }

    private static func validOwner(_ value: String) -> Bool {
        guard value != ".", value != "..", value.count <= 39 else { return false }
        return value.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }

    private static func validRepo(_ value: String) -> Bool {
        guard value != ".", value != "..", !value.isEmpty else { return false }
        return value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func request(
        _ path: String,
        token: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let data = try await raw(path, token: token, method: method, body: body)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else { throw GitHubError.api("Expected object") }
        return dict
    }

    private static func requestArray(_ path: String, token: String) async throws -> [[String: Any]] {
        let data = try await raw(path, token: token, method: "GET", body: nil)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let list = obj as? [[String: Any]] else { throw GitHubError.api("Expected array") }
        return list
    }

    private static func raw(
        _ path: String,
        token: String,
        method: String,
        body: [String: Any]?
    ) async throws -> Data {
        guard let url = URL(string: api + path) else { throw GitHubError.api("Bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VulkanGlass/0.2.1", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code < 200 || code >= 300 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.api("GitHub \(code): \(text.prefix(240))")
        }
        return data
    }
}
