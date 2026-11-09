import Foundation

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var query: [URLQueryItem] = []
    public var headers: [String: String] = [:]
    public var body: Data?

    public init(method: String, path: String, query: [URLQueryItem] = [],
                headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Real transport. The device token goes in the Authorization header and nowhere else.
public struct URLSessionTransport: HTTPTransport {
    public let baseURL: URL
    public let token: String
    public let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(request.path), resolvingAgainstBaseURL: false)!
        if !request.query.isEmpty { components.queryItems = request.query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = request.method
        req.httpBody = request.body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
