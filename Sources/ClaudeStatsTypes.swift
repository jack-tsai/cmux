import Foundation

// MARK: - Claude Code statusline stdin JSON (Sources:
// https://code.claude.com/docs/en/statusline.md). All fields are optional so
// forward-compatible Claude Code versions adding new keys never prevent cmux
// from ingesting the known subset (decision: "Schema tolerance for Claude Code
// version drift").

public struct ClaudeStatsStatuslinePayload: Codable, Equatable, Sendable {

    public struct ModelInfo: Codable, Equatable, Sendable {
        public let id: String?
        public let displayName: String?

        public init(id: String?, displayName: String?) {
            self.id = id
            self.displayName = displayName
        }

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    public struct WorkspaceInfo: Codable, Equatable, Sendable {
        public let currentDir: String?
        public let projectDir: String?

        public init(currentDir: String?, projectDir: String?) {
            self.currentDir = currentDir
            self.projectDir = projectDir
        }

        enum CodingKeys: String, CodingKey {
            case currentDir = "current_dir"
            case projectDir = "project_dir"
        }
    }

    public struct CostInfo: Codable, Equatable, Sendable {
        public let totalCostUsd: Double?
        public let totalDurationMs: Int?
        public let totalApiDurationMs: Int?
        public let totalLinesAdded: Int?
        public let totalLinesRemoved: Int?

        public init(totalCostUsd: Double?, totalDurationMs: Int?, totalApiDurationMs: Int?,
                    totalLinesAdded: Int?, totalLinesRemoved: Int?) {
            self.totalCostUsd = totalCostUsd
            self.totalDurationMs = totalDurationMs
            self.totalApiDurationMs = totalApiDurationMs
            self.totalLinesAdded = totalLinesAdded
            self.totalLinesRemoved = totalLinesRemoved
        }

        enum CodingKeys: String, CodingKey {
            case totalCostUsd = "total_cost_usd"
            case totalDurationMs = "total_duration_ms"
            case totalApiDurationMs = "total_api_duration_ms"
            case totalLinesAdded = "total_lines_added"
            case totalLinesRemoved = "total_lines_removed"
        }
    }

    public struct ContextUsage: Codable, Equatable, Sendable {
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let cacheCreationInputTokens: Int?
        public let cacheReadInputTokens: Int?

        public init(inputTokens: Int?, outputTokens: Int?,
                    cacheCreationInputTokens: Int?, cacheReadInputTokens: Int?) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    public struct ContextWindow: Codable, Equatable, Sendable {
        public let totalInputTokens: Int?
        public let totalOutputTokens: Int?
        public let contextWindowSize: Int?
        public let usedPercentage: Double?
        public let remainingPercentage: Double?
        public let currentUsage: ContextUsage?

        public init(totalInputTokens: Int?, totalOutputTokens: Int?,
                    contextWindowSize: Int?, usedPercentage: Double?,
                    remainingPercentage: Double?, currentUsage: ContextUsage?) {
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.contextWindowSize = contextWindowSize
            self.usedPercentage = usedPercentage
            self.remainingPercentage = remainingPercentage
            self.currentUsage = currentUsage
        }

        enum CodingKeys: String, CodingKey {
            case totalInputTokens = "total_input_tokens"
            case totalOutputTokens = "total_output_tokens"
            case contextWindowSize = "context_window_size"
            case usedPercentage = "used_percentage"
            case remainingPercentage = "remaining_percentage"
            case currentUsage = "current_usage"
        }
    }

    public struct RateLimitWindow: Codable, Equatable, Sendable {
        public let usedPercentage: Double?
        /// Unix epoch seconds.
        public let resetsAt: Int?

        public init(usedPercentage: Double?, resetsAt: Int?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    public struct RateLimits: Codable, Equatable, Sendable {
        public let fiveHour: RateLimitWindow?
        public let sevenDay: RateLimitWindow?

        public init(fiveHour: RateLimitWindow?, sevenDay: RateLimitWindow?) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
        }

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    public let sessionId: String?
    public let cwd: String?
    public let transcriptPath: String?
    public let model: ModelInfo?
    public let workspace: WorkspaceInfo?
    public let version: String?
    public let cost: CostInfo?
    public let contextWindow: ContextWindow?
    public let exceeds200kTokens: Bool?
    public let rateLimits: RateLimits?

    public init(
        sessionId: String? = nil,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        model: ModelInfo? = nil,
        workspace: WorkspaceInfo? = nil,
        version: String? = nil,
        cost: CostInfo? = nil,
        contextWindow: ContextWindow? = nil,
        exceeds200kTokens: Bool? = nil,
        rateLimits: RateLimits? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.model = model
        self.workspace = workspace
        self.version = version
        self.cost = cost
        self.contextWindow = contextWindow
        self.exceeds200kTokens = exceeds200kTokens
        self.rateLimits = rateLimits
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case model
        case workspace
        case version
        case cost
        case contextWindow = "context_window"
        case exceeds200kTokens = "exceeds_200k_tokens"
        case rateLimits = "rate_limits"
    }
}

// MARK: - Stored snapshot

public struct ClaudeStatsSnapshot: Equatable, Sendable {
    public let surfaceId: UUID
    public let sessionId: String
    public let receivedAt: Date
    public let payload: ClaudeStatsStatuslinePayload

    public init(
        surfaceId: UUID,
        sessionId: String,
        receivedAt: Date,
        payload: ClaudeStatsStatuslinePayload
    ) {
        self.surfaceId = surfaceId
        self.sessionId = sessionId
        self.receivedAt = receivedAt
        self.payload = payload
    }

    /// Threshold: 30 s since last update. Exposed as a static so tests can
    /// supply a custom `now` while production callers get the canonical value.
    public static let stalenessThreshold: TimeInterval = 30

    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(receivedAt) > Self.stalenessThreshold
    }
}

// MARK: - Compact counter persistence entry

public struct ClaudeCompactCountEntry: Codable, Equatable, Sendable {
    public var count: Int
    public var lastSeen: Date

    public init(count: Int, lastSeen: Date) {
        self.count = count
        self.lastSeen = lastSeen
    }
}
