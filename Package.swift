// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Humanist",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Humanist", targets: ["Humanist"]),
        .library(name: "Document", targets: ["Document"]),
        .library(name: "PDFIngest", targets: ["PDFIngest"]),
        .library(name: "OCR", targets: ["OCR"]),
        .library(name: "EPUB", targets: ["EPUB"]),
        .library(name: "Pipeline", targets: ["Pipeline"]),
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
        .target(
            name: "OCR",
            dependencies: ["Document"],
            path: "Sources/OCR"
        ),
        .target(
            name: "EPUB",
            dependencies: ["Document", "ZIPFoundation"],
            path: "Sources/EPUB"
        ),
        .target(
            name: "Pipeline",
            dependencies: ["Document", "PDFIngest", "OCR", "EPUB"],
            path: "Sources/Pipeline"
        ),
        .executableTarget(
            name: "Humanist",
            dependencies: ["Pipeline"],
            path: "Sources/Humanist"
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
            dependencies: ["Pipeline", "Document", "EPUB"],
            path: "Tests/PipelineTests"
        ),
    ]
)
