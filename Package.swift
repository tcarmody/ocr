// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Humanist",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Humanist", targets: ["Humanist"]),
        .library(name: "Document", targets: ["Document"]),
        .library(name: "PDFIngest", targets: ["PDFIngest"]),
        .library(name: "OCR", targets: ["OCR"]),
        .library(name: "EPUB", targets: ["EPUB"]),
        .library(name: "Layout", targets: ["Layout"]),
        .library(name: "Pipeline", targets: ["Pipeline"]),
        .library(name: "AI", targets: ["AI"]),
    ],
    dependencies: [
        // ZIPFoundation handles the ZIP packaging — most importantly the
        // mimetype-first-and-uncompressed rule that EPUB requires.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "Document",
            path: "Sources/Document"
        ),
        .target(
            name: "PDFIngest",
            dependencies: ["Document"],
            path: "Sources/PDFIngest"
        ),
        // C bridge for libtesseract + libleptonica. Phase 3.5a links
        // against the brew-installed dylibs at /opt/homebrew. Phase
        // 3.5b will switch to vendored dylibs in Vendor/tesseract/.
        .systemLibrary(
            name: "CTesseract",
            path: "Sources/CTesseract"
        ),
        .target(
            name: "OCR",
            dependencies: ["Document", "CTesseract"],
            path: "Sources/OCR",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"])
            ]
        ),
        .target(
            name: "EPUB",
            dependencies: ["Document", "ZIPFoundation"],
            path: "Sources/EPUB"
        ),
        // Surya layout sidecar bridge. Phase 4 lite: requires user to
        // `uv tool install surya-ocr`; the bridge auto-detects the
        // tool's Python interpreter at runtime. Phase 4.6 will bundle
        // the runtime + weights into the .app.
        .target(
            name: "Layout",
            dependencies: ["Document", "OCR"],
            path: "Sources/Layout"
        ),
        .target(
            name: "Pipeline",
            dependencies: ["Document", "PDFIngest", "OCR", "EPUB", "Layout", "AI"],
            path: "Sources/Pipeline"
        ),
        // Anthropic API plumbing for optional Cloud-mode features.
        // Pure data types + a URLSession transport — depends on no
        // OCR / PDF / EPUB code. Pipeline + Humanist depend on this
        // when (in later phases) Claude-backed engines are wired in.
        // The transport is split behind a protocol so a future bulk
        // path (Messages Batches API) reuses the same request /
        // response types without touching the synchronous client.
        .target(
            name: "AI",
            path: "Sources/AI"
        ),
        .executableTarget(
            name: "Humanist",
            dependencies: ["Pipeline", "AI", "PDFIngest"],
            path: "Sources/Humanist"
        ),
        // One-shot CLI for the Cloud-mode validation spike (PLANS.md
        // Tier 2 Phase 4). Compares CER of `.privateLocal` vs `.cloud`
        // pipeline output against a hand-corrected RTF reference.
        // Not part of `swift test` — needs the user's API key + spends
        // tokens. Invoke via `swift run SpikeRunner`.
        .executableTarget(
            name: "SpikeRunner",
            dependencies: ["Pipeline", "AI", "EPUB", "ZIPFoundation"],
            path: "Sources/SpikeRunner"
        ),
        .testTarget(
            name: "EPUBTests",
            dependencies: ["EPUB", "Document"],
            path: "Tests/EPUBTests"
        ),
        .testTarget(
            name: "DocumentTests",
            dependencies: ["Document"],
            path: "Tests/DocumentTests"
        ),
        .testTarget(
            name: "PipelineTests",
            dependencies: ["Pipeline", "Document", "EPUB", "PDFIngest", "AI"],
            path: "Tests/PipelineTests"
        ),
        .testTarget(
            name: "AITests",
            dependencies: ["AI"],
            path: "Tests/AITests"
        ),
        // Tests for `Humanist` executable internals (JobRunner /
        // JobStore / coordinator classes). UI views aren't covered
        // here — focus is on the testable model + runner state
        // machines that don't need a window to exercise.
        .testTarget(
            name: "HumanistTests",
            dependencies: ["Humanist"],
            path: "Tests/HumanistTests"
        ),
    ],
    // Tools-version 6.2 (required for `.v26`) defaults to Swift 6
    // strict concurrency; the codebase was written under Swift 5
    // and migrating is out of scope for the platform bump.
    swiftLanguageModes: [.v5]
)
