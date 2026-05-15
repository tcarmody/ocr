// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Humanist",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Humanist", targets: ["Humanist"]),
        .executable(name: "humanist-cli", targets: ["HumanistCLI"]),
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
        // Apple's official command-line argument parser. Used by the
        // `humanist-cli` executable target.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
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
                // `-weak-l` marks the libraries (and all their imported
                // symbols) as weak, so dyld lets the binary launch when
                // the dylibs are absent. Every call site is gated by
                // `TesseractOCREngine.detect()`, which probes the dylib
                // via `dlsym` before touching any Tesseract symbol —
                // so a null function pointer never gets called.
                //
                // At distribute time we bundle the dylibs into
                // `Contents/Frameworks/` via `Scripts/build-app.sh`
                // (Phase B); the runtime resolver tries the bundled
                // copies first, then falls back to Homebrew. Users on
                // a Mac with no Tesseract installation at all get
                // the bundled dylibs and the app just works.
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-Xlinker", "-weak-ltesseract",
                    "-Xlinker", "-weak-lleptonica",
                ])
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
        // Command-line interface to the conversion pipeline.
        // Same engines as the SwiftUI app, exposed as `humanist-cli`
        // so conversions can be scripted, run in CI, or used in
        // shell pipelines. See Sources/HumanistCLI/README for the
        // full command reference.
        .executableTarget(
            name: "HumanistCLI",
            dependencies: [
                "Document", "PDFIngest", "OCR", "EPUB", "Layout",
                "Pipeline", "AI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/HumanistCLI",
            // README is documentation, not a resource SPM should bundle.
            exclude: ["README.md"]
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
    // Swift 6 strict concurrency mode. Per-pass debug state was
    // refactored from static-mutable singletons into return-value
    // structs (`RegionAwareReflow.Diagnostics`,
    // `TwoUpDetector.Detection`); LoadedPDF carries an `@unchecked
    // Sendable` defense documented in `PDFLoader.swift`; Sendable-
    // unsafe wire formats (e.g. SidecarBridge) flipped to `Data`.
    swiftLanguageModes: [.v6]
)
