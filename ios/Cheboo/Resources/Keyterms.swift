import Foundation

/// Static keyterm seeding for Deepgram's `keyterm=` parameter (capped at 100).
/// These are passed at connection time and bias the model toward dev jargon.
enum Keyterms {
    static let defaults: [String] = [
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
}
