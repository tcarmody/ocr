import Foundation
import CoreGraphics
import ImageIO
import AI
import OCR
import Pipeline

/// Live smoke test for `LandingAIDocumentEngine`. Reads a single image
/// from disk, sends it to LandingAI's `/v1/ade/parse` endpoint, prints
/// the returned markdown. Not part of `swift test` — hits the live API
/// and spends credits. Invoke via:
///
///     swift run LandingAISmoke /path/to/page.png
///
/// API key resolution order: `VISION_AGENT_API_KEY` env var, then the
/// keychain entry written by `LandingAIAPIKeyStore`.
@main
struct LandingAISmoke {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data(
                "usage: LandingAISmoke <image-path>\n".utf8
            ))
            exit(2)
        }
        let path = args[1]

        let envKey = ProcessInfo.processInfo.environment["VISION_AGENT_API_KEY"]
        let storedKey = LandingAIAPIKeyStore().read()
        guard let key = envKey ?? storedKey, !key.isEmpty else {
            FileHandle.standardError.write(Data(
                "error: set VISION_AGENT_API_KEY or store one via LandingAIAPIKeyStore\n".utf8
            ))
            exit(1)
        }

        guard let image = loadImage(path: path) else {
            FileHandle.standardError.write(Data(
                "error: could not load image at \(path)\n".utf8
            ))
            exit(1)
        }

        let engine = LandingAIDocumentEngine(
            apiKeyProvider: { key },
            budget: ClaudeCallBudget(cap: 1)
        )

        do {
            let start = Date()
            let result = try await engine.recognize(
                image: image,
                hints: OCRHints()
            )
            let elapsed = Date().timeIntervalSince(start)
            print("--- markdown (\(result.text.count) chars, \(String(format: "%.2f", elapsed))s) ---")
            print(result.text)
        } catch {
            FileHandle.standardError.write(Data(
                "error: \(error.localizedDescription)\n".utf8
            ))
            exit(1)
        }
    }

    private static func loadImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
