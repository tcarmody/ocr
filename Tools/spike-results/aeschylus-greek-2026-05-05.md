# Spike — grc — Aeschylus.pdf

Run 2026-05-05T17:09:38Z. Document: [/Users/tim/Desktop/Aeschylus.pdf](/Users/tim/Desktop/Aeschylus.pdf). Ground truth: 4132 normalized chars.

## Results

| Mode | Norm chars | Edit distance | CER | Elapsed | Claude obs |
|---|---:|---:|---:|---:|---:|
| `.privateLocal` | 3914 | 622 | 15.1% | 18.4s | — |
| `.cloud` | 3914 | 622 | 15.1% | 16.5s | 0 |

**Verdict**: `.cloud` mode produced **byte-identical output** to `.privateLocal`. The cascade's Stage 3 (Claude) **never fired** — after Stage 1 (Surya whole-page re-OCR), no regions remained problematic enough to escalate. Surya's polytonic Greek output was good enough that Vision's deficits were patched and the result passed the quality floor. Claude saw zero pages.

## What this tells us

1. **The cascade does what it's supposed to.** Cost guardrails work: when local engines handle the material, Cloud mode incurs no cost.
2. **Surya is competent on classical Greek scan-quality input.** ~15% CER from a Vision → Surya cascade on rasterized polytonic Greek is a real number, not great but a baseline. Most of the errors are diacritic / breathing-mark variants, not gross word-level OCR failures.
3. **This is a green light for Cloud mode as designed**, *not* a verdict on whether Claude would beat Surya in absolute terms. The cascade simply didn't ask Claude.

## Caveats / what we still don't know

- **Whether Claude would have done better in absolute terms.** A "Claude-only" run that bypasses Surya entirely and feeds every region to Sonnet would tell us. Worth a follow-up experiment.
- **Whether Cloud mode helps on harder input.** This document is rasterized from a clean digital source — print quality is excellent. Real-world polytonic Greek scans (Loeb, OCT, Teubner facsimiles) have faded ink, fainter diacritics, and noise that may push the cascade to escalate. Need a scan-source fixture to test.
- **Hebrew, Syriac, Coptic.** Untested. If Surya handles those as well as it handles Greek here, Cloud mode's value proposition narrows considerably.
- **The 15.1% CER itself.** Looking at the failure modes (whether it's diacritic confusion, line-break/whitespace artifacts, or gross word errors) would tell us where the cascade is weak — useful regardless of Cloud mode.

## Recommendation

Don't draw the "Cloud is unnecessary" conclusion from this single doc — Claude didn't get a chance to demonstrate value. Two follow-up experiments before deciding:

1. **Claude-only baseline.** Add a third mode to the spike that disables Surya + Tesseract from the cascade, forcing Claude to handle every region. Compare CER directly. Tells us "would Claude beat Surya if it fired?"
2. **Harder fixture.** A scanned-facsimile polytonic Greek page (visibly lower print quality) to see whether the local cascade actually escalates and whether Claude meaningfully improves over Surya in those cases.

Both are small extensions of the existing harness. Pick up after Hebrew + Latin ground truth lands.

## Methodology

- CER = Levenshtein distance / ground-truth length, on whitespace-normalized text.
- No lowercasing or punctuation stripping — case, diacritics, and punctuation all count as character errors.
- Both modes use the same `PDFToEPUBPipeline` with the same DPI, OCR quality, and language hints; only `processingMode` + `cloudFeatures.hardRegionOCR` differ.
- `.cloud` enables the Phase 3 `ClaudeOCREngine` as cascade Stage 3 (after Vision → Surya → Tesseract). Each call is guardrail-gated against the prior tier; rejected results keep the prior text.
- The Claude-observation count is parsed from the debug log (`src=c` lines) — it counts emitted observations, not raw API call attempts (so guardrail rejections, refusals, and budget-exhausted skips don't show up).

## Caveats

- Single document, single script. A directional signal, not a verdict — extending to Hebrew + Latin scans before drawing conclusions about whole-corpus tradeoffs.
- The `.cloud` Stage 3 only fires on regions the prior tiers flagged. If Vision + Tesseract did well enough on this document, Cloud's advantage will be small here even if it's large on harder material.
- The pipeline produces an EPUB, then we strip HTML to compare text. Whitespace + paragraph break differences can inflate CER by a few characters per region — both modes pay the same penalty.
