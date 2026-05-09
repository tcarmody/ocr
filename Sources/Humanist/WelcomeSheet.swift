import SwiftUI
import Layout

/// First-run welcome sheet. Presented automatically when
/// `@AppStorage(welcomeShownKey)` is false; the user dismisses it
/// by clicking "Got it" (which flips the flag) or by opening
/// Settings (which also flips the flag — there's nothing to come
/// back to). Help > Show Welcome reopens it on demand without
/// resetting the flag.
///
/// Content is intentionally short: the app is mostly self-evident
/// (drop PDFs, get EPUBs), so the sheet's job is to point out the
/// non-obvious bits — Cloud-mode trade-offs, where output goes,
/// the queue's ability to process whole folders.
struct WelcomeSheet: View {
    /// `@AppStorage` key the sheet flips on dismiss. Same key is
    /// used by `HumanistApp` to decide whether to present on launch.
    static let welcomeShownKey = "humanist.welcomeShown"

    @Binding var isPresented: Bool
    @AppStorage(welcomeShownKey) private var welcomeShown: Bool = false
    @Environment(\.openSettings) private var openSettings
    @State private var showingSuryaSetup = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    quickStart
                    Divider()
                    suryaSection
                    Divider()
                    cloudSection
                    Divider()
                    privacyNote
                }
                .padding(28)
            }
            footerBar
        }
        .frame(width: 560, height: 600)
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Humanist")
                .font(.largeTitle.bold())
            Text("PDF → EPUB conversion for academic books, with optional Claude assistance for the hard cases.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick start").font(.headline)
            bullet(
                systemImage: "doc.fill.badge.plus",
                title: "Drop a PDF (or a folder of PDFs)",
                detail: "Anywhere on the launcher window. Folders enumerate recursively. Each PDF becomes a queued job."
            )
            bullet(
                systemImage: "rectangle.split.2x1",
                title: "Two-up scans get auto-split",
                detail: "When the queue detects facing pages on one PDF page, it'll prompt to split before OCR."
            )
            bullet(
                systemImage: "globe",
                title: "Language auto-detect",
                detail: "The queue samples each PDF and picks the right language for OCR — overrides the picker when confident."
            )
            bullet(
                systemImage: "doc.richtext",
                title: "Output lands next to the source",
                detail: "book.pdf → book.epub. Open in any EPUB reader (Books, Calibre, Thorium); also opens in Humanist's own editor for review."
            )
        }
    }

    @ViewBuilder
    private var suryaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Layout analysis").font(.headline)
                if SuryaConnection.shared == nil {
                    Text("not installed")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                } else {
                    Text("ready")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                }
            }
            Text("Surya analyses page layout before OCR — classifying regions as headings, body text, footnotes, figures, and tables. This drives chapter structure, footnote linking, and table extraction.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if SuryaConnection.shared == nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Surya is not installed. Conversions will use Apple Vision OCR only — functional, but with less structure detection.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Set up Surya…") {
                    showingSuryaSetup = true
                }
                .buttonStyle(.borderedProminent)
                .sheet(isPresented: $showingSuryaSetup) {
                    SuryaSetupSheet(isPresented: $showingSuryaSetup)
                }
            }
        }
    }

    @ViewBuilder
    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Cloud features").font(.headline)
                Text("optional, off by default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Cloud mode adds Claude-backed engines for cases the local cascade can't fix on its own — hard scripts, mixed-language pages, post-OCR character cleanup, semantic chapter labels. Bring your own Anthropic API key.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            bullet(
                systemImage: "eye.trianglebadge.exclamationmark",
                title: "Hard-region OCR (Sonnet)",
                detail: "Polytonic Greek, Hebrew, and other scripts where Vision and Tesseract miss diacritics. Fires only on regions the local cascade flagged."
            )
            bullet(
                systemImage: "wand.and.stars",
                title: "Post-OCR cleanup (Haiku)",
                detail: "Fixes character-level OCR errors — ligatures, missing diacritics, long-s misreads. Editor's Document > Show Correction Trail surfaces every change."
            )
            bullet(
                systemImage: "list.bullet.rectangle",
                title: "Printed-TOC parsing & semantic classification (Haiku)",
                detail: "One Haiku call per book reads the printed table of contents into authoritative chapter titles + nav.xhtml entries; semantic classification labels each chapter (preface, appendix, bibliography, etc.)."
            )
            bullet(
                systemImage: "dollarsign.circle",
                title: "Pre-flight cost estimate",
                detail: "Drop a PDF and the queue row shows the expected Claude call count + dollar cost before you click Convert. The per-book cap caps actual spend at the runtime ceiling."
            )
        }
    }

    @ViewBuilder
    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Private mode is the default", systemImage: "lock.shield")
                .font(.headline)
            Text("With Private mode (the default), every page is processed locally — Vision, Tesseract, Surya — and no data leaves your machine. Cloud features only run when you explicitly enable them in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footerBar: some View {
        HStack {
            Button("Open Settings…") {
                welcomeShown = true
                isPresented = false
                openSettings()
            }
            Spacer()
            Button("Got it") {
                welcomeShown = true
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Bullet helper

    @ViewBuilder
    private func bullet(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24, alignment: .center)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
