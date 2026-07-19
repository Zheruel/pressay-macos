import Foundation

/// Conservative defaults for agent-driven software work, pruned to terms that
/// fire in practice and seeded with audited mishearings (Kimmy, Cloud Code,
/// Entropic, Whisperflow, Rumpod, SoonerCloud). Common English words with
/// technical meanings (Go, React, REST, Linear, Terminal) are omitted because
/// global rewriting would corrupt ordinary messages.
package enum CuratedVocabulary {
    package static let source = """
    # Communication and AI agents
    Slack
    Kimi Code <= kimi code
    Kimi <= kimmy, akimi
    Claude Code <= claude code, cloud code
    Claude
    Anthropic <= entropic
    Codex
    OpenAI <= open ai
    ChatGPT <= chat gpt
    Wispr Flow <= whisper flow, whisperflow
    SonarCloud <= soonercloud, sooner cloud
    RunPod <= rumpod
    TL;DR <= tldr

    # Apple development
    SwiftUI <= swift ui
    SwiftData <= swift data
    Core ML <= core ml, coreml
    FluidAudio <= fluid audio
    WhisperKit <= whisper kit
    macOS <= mac os
    Apple Silicon

    # Developer workflow
    GitHub <= git hub
    GitLab <= git lab
    VS Code <= vs code, v s code
    Node.js <= node js, node dot js
    Next.js <= next js, next dot js
    PostgreSQL <= postgres sql
    Docker
    Markdown
    PR <= p r
    API <= a p i
    JSON <= j s o n
    .env <= dot env
    package.json <= package json
    """

    /// Exact stock defaults from earlier builds; only these are migrated.
    package static let replaceableDefaults: Set<String> = [
        """
        SwiftUI
        SwiftData
        Core ML <= coreml, core ml
        WhisperKit <= whisper kit
        FluidAudio <= fluid audio
        """,
        """
        SwiftUI <= swift ui
        SwiftData <= swift data
        Core ML <= coreml, core ml
        WhisperKit <= whisper kit
        FluidAudio <= fluid audio
        macOS <= mac os
        """,
        """
        # Communication and AI agents
        Slack
        DM <= d m
        AI
        LLM <= l l m
        OpenAI <= open ai
        ChatGPT <= chat gpt
        Codex
        Claude
        Anthropic
        GitHub Copilot <= git hub copilot
        MCP <= m c p
        RAG <= r a g

        # Source control, editors, and developer workflow
        GitHub <= git hub
        GitLab <= git lab
        Bitbucket <= bit bucket
        VS Code <= vs code, v s code, visual studio code
        PR <= p r
        CI/CD <= ci cd, c i c d
        DevOps <= dev ops
        Homebrew <= home brew
        API <= a p i
        SDK <= s d k
        CLI <= c l i
        UI <= u i
        UX <= u x
        URL <= u r l
        URI <= u r i
        HTTP <= h t t p
        HTTPS <= h t t p s

        # Apple development
        Swift
        SwiftUI <= swift ui
        SwiftData <= swift data
        AppKit <= app kit
        UIKit <= ui kit
        Xcode <= x code
        XCTest <= x c test, x test
        macOS <= mac os, mac o s
        iOS <= i os, i o s
        Core ML <= core ml, coreml
        WhisperKit <= whisper kit
        FluidAudio <= fluid audio
        Apple Silicon
        MLX <= m l x
        MainActor <= main actor
        ObservableObject <= observable object
        Codable
        Sendable
        AVAudioEngine <= av audio engine, a v audio engine
        AVAudioConverter <= av audio converter, a v audio converter
        Swift Package Manager
        SPM <= s p m

        # Languages, formats, and web tooling
        JavaScript <= java script
        TypeScript <= type script
        Node.js <= node js, node dot js
        Next.js <= next js, next dot js
        Python
        PyTorch <= py torch
        Kotlin
        C++ <= c plus plus
        C# <= c sharp
        HTML <= h t m l
        CSS <= c s s
        JSON <= j s o n
        YAML <= y a m l
        XML <= x m l
        Markdown
        Bash
        Zsh <= z shell
        npm <= n p m
        pnpm <= p n p m
        Vite
        ESLint <= e s lint
        Tailwind CSS <= tailwind css
        GraphQL <= graph ql, graph q l
        REST API <= rest api
        WebSocket <= web socket
        OAuth <= o auth
        JWT <= j w t
        OpenAPI <= open api
        FastAPI <= fast api

        # Data and infrastructure
        PostgreSQL <= postgres sql
        Postgres
        MySQL <= my sql
        SQLite <= sql lite, sequel lite
        MongoDB <= mongo db
        Redis
        Supabase <= supa base
        Firebase <= fire base
        Docker
        Kubernetes
        Terraform <= terra form
        AWS <= a w s
        GCP <= g c p
        Azure
        Cloudflare <= cloud flare
        Vercel <= ver sell
        Netlify

        # Commonly dictated identifiers and files
        camelCase <= camel case
        PascalCase <= pascal case
        snake_case <= snake case
        kebab-case <= kebab case
        .env <= dot env
        .gitignore <= git ignore
        package.json <= package json
        tsconfig.json <= ts config json
        """,
    ]
}
