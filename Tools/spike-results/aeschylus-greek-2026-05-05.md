# Spike — grc — Aeschylus.pdf

Run 2026-05-05T17:28:04Z. Document: [/Users/tim/Desktop/Aeschylus.pdf](/Users/tim/Desktop/Aeschylus.pdf). Ground truth: 4132 normalized chars.

## Results

| Mode | Norm chars | Edit distance | CER | Elapsed | Claude obs |
|---|---:|---:|---:|---:|---:|
| `.privateLocal` | 3914 | 622 | 15.1% | 18.1s | — |
| `.cloud` (full cascade) | 3914 | 622 | 15.1% | 16.5s | 0 |
| `.cloud` claude-only | 4122 | 465 | 11.3% | 175.8s | 23 |

**`.privateLocal` vs `.cloud`** (full cascade): Effectively a tie (Δ ≤ 0.5 pp).

**`.privateLocal` vs `.cloud` claude-only**: Claude wins by 3.8 pp.

**`.cloud` (full cascade) vs claude-only**: Claude-only wins by 3.8 pp.

## Findings

1. **Tesseract on polytonic Greek is competitive.** `selectEngine` correctly routes `grc` to Tesseract (which has `grc_best` traineddata), and Tesseract delivers 15.1% CER. That's not great in absolute terms, but it's a real working baseline — diacritic / line-break artifacts dominate the error budget, not gross word-level OCR failures.
2. **The cascade as designed never invokes Claude on this kind of input.** Tesseract's output passes the cascade's quality floor (`meanConfidence ≥ 0.85`, `textQuality ≥ 0.5`) cleanly. Cloud mode adds zero observations — and zero cost.
3. **Claude beats the local stack by 3.8 pp when given the chance** (11.3% CER). Materially better on its own, but the local stack already cleared the cascade's quality bar, so the cascade never asked Claude. The bar is the binding constraint, not Claude's quality.
4. **Latency is ~10× higher for Claude-only.** 175s vs 18s for 5 pages. ~35s/page vs Surya layout + Tesseract OCR's ~3.5s/page.
5. **Cost was ~$0.10** for 23 successful Claude calls (Sonnet 4.6). Well under the per-book cap.

## Implication: the cascade's quality floor is too generous for classical scripts

The cascade was tuned against Latin-script body text, where Vision's confidence is well-calibrated. Tesseract on polytonic Greek hits high confidence even when it's making predictable errors (dropped breathing marks, miscategorized accents). Two ways to tighten this for Cloud-mode users who actually want Claude's quality:

- **Per-script lower confidence floor** — when languages include `grc`/`he`/`syr`/`cop`, raise `meanConfidenceFloor` (e.g., to 0.95) so Tesseract's "confident enough" output still escalates.
- **A "prefer Claude when available" Cloud toggle** that bypasses the quality floor on any region with a flagged-script language hint — opt-in to "Claude transcribes everything in this script" semantics with a clear cost expectation.

Both are small changes, but they're real product decisions, not just plumbing. Worth holding off on until we have Hebrew + Latin data points too — Latin would tell us whether the floor is actually well-tuned for the common case (and we just need to special-case rare scripts), or whether the cascade is uniformly under-escalating.

## Caveats

- Single document, single script. Claude's 3.8 pp win on this fixture is meaningful but not proof of a general pattern.
- Print quality here is excellent (rasterized digital source). On low-quality scans both engines would degrade, but Claude likely degrades less. Need a scan fixture to confirm.
- The 23 Claude observations < the full set of text-bearing regions across 5 pages — some calls failed silently (refusal / decode / network). Worth instrumenting if we make Claude-only a real production mode.
- **Do not productionize `disableLocalCascadeEscalation`.** It bypasses the guardrail layer that protects against hallucinated Claude rewrites. The right production answer to "use Claude more" is to tighten the quality floor (above), not bypass the guardrail.

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
