import Foundation

/// A named bundle of keyterms the user can switch between. Deepgram's
/// `keyterm=` parameter biases the model toward project- or domain-specific
/// vocabulary; different projects want different vocabularies, so we let the
/// user keep multiple lists side by side and pick one at a time (or none).
struct KeytermList: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var terms: [String]

    init(id: UUID = UUID(), name: String, terms: [String]) {
        self.id = id
        self.name = name
        self.terms = terms
    }
}

enum Keyterms {
    /// Seed terms used the first time the app launches (or whenever the user
    /// hits "Reset to defaults"). Captures dev jargon Deepgram routinely
    /// mis-transcribes — language names, CLIs, vendors, file paths.
    static let defaultTerms: [String] = [
        // Languages
        "JavaScript", "TypeScript", "Python", "Swift", "Rust", "Golang", "Kotlin",
        "Ruby", "Elixir", "Haskell", "Zig",
        // Frameworks / runtimes
        "React", "Vue", "Svelte", "SwiftUI", "AppKit", "UIKit", "Next.js",
        "Node.js", "Deno", "Bun", "FastAPI", "Django", "Rails",
        // Shell + CLI
        "kubectl", "docker", "git", "rebase", "cherry-pick", "npm", "pnpm",
        "yarn", "cargo", "ssh", "scp", "rsync", "grep", "sed", "awk", "tmux",
        "ripgrep", "fzf",
        // Dev jargon
        "API", "JSON", "YAML", "WebSocket", "OAuth", "JWT", "gRPC", "GraphQL",
        "CRUD", "WASM", "regex", "stdout", "stderr", "stdin",
        // Vendors / products
        "Anthropic", "Claude", "Deepgram", "OpenAI", "Cloudflare", "Vercel",
        "Supabase", "Postgres", "Redis", "SQLite",
        // Tools
        "Ghostty", "Cursor", "Xcode", "VS Code", "Neovim", "JetBrains",
        // Files / paths
        "package.json", "pyproject.toml", "Cargo.toml", "tsconfig.json",
        "Dockerfile", "Makefile", "README", ".env",
    ]

    /// The bundled "Default" list. Used the first time the user opens
    /// settings, or to seed `Reset to defaults` actions.
    static func defaultList() -> KeytermList {
        KeytermList(name: "Default", terms: defaultTerms)
    }

    /// Back-compat constant for callers that still want the flat string list.
    static let defaults: [String] = defaultTerms
}
