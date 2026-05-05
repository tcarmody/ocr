import Foundation

/// User-facing toggle for whether the conversion pipeline is allowed
/// to call out to Claude.
///
/// `.private` keeps everything on-device — Vision, Tesseract, Surya.
/// No data leaves the machine.
///
/// `.cloud` unlocks Claude-backed engines (hard-region OCR, table
/// extraction, post-OCR cleanup, semantic classification, TOC
/// parsing). Each Cloud feature is independently togglable in
/// settings; this enum is just the master switch.
public enum ProcessingMode: String, Sendable, Codable, Equatable, CaseIterable {
    /// Local-only. No network calls for AI.
    case privateLocal = "private"
    /// Claude-backed features available (per-feature toggles still apply).
    case cloud = "cloud"
}
