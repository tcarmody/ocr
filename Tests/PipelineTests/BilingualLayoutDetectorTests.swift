import XCTest
import CoreGraphics
import OCR
@testable import Pipeline

final class BilingualLayoutDetectorTests: XCTestCase {

    // MARK: - positive cases

    func test_detects_loeb_style_greek_english_alternation() {
        // 12 pages alternating Greek and English. The detector
        // identifies the Greek side via the Greek Unicode-script
        // ratio (NLR conflates ancient + modern Greek into `el`,
        // so we side-step it for the script-based gate).
        let pages = makePages(
            alternating: [greek, english], count: 12, startIndex: 2
        )
        guard let layout = BilingualLayoutDetector.detect(pageResults: pages) else {
            XCTFail("expected detection on facing-page Greek/English alternation")
            return
        }
        XCTAssertEqual(layout.l1Language, "grc")
        XCTAssertEqual(layout.l2Language, "en")
        XCTAssertGreaterThanOrEqual(
            layout.alternationRate,
            BilingualLayoutDetector.alternationThreshold
        )
        XCTAssertEqual(layout.pagePartners[2], 3)
        XCTAssertEqual(layout.pagePartners[3], 2)
    }

    func test_detects_latin_english_alternation() {
        let pages = makePages(
            alternating: [latin, english], count: 12, startIndex: 2
        )
        guard let layout = BilingualLayoutDetector.detect(pageResults: pages) else {
            XCTFail("expected detection on facing-page Latin/English alternation")
            return
        }
        XCTAssertEqual(layout.l1Language, "la")
        XCTAssertEqual(layout.l2Language, "en")
        XCTAssertGreaterThanOrEqual(
            layout.alternationRate,
            BilingualLayoutDetector.alternationThreshold
        )
        // Every alternating-pair entry is symmetric.
        for (k, v) in layout.pagePartners {
            XCTAssertEqual(layout.pagePartners[v], k,
                           "partner map must be symmetric")
        }
        // Page 2 (Latin) pairs with page 3 (English).
        XCTAssertEqual(layout.pagePartners[2], 3)
        XCTAssertEqual(layout.pagePartners[3], 2)
    }

    // MARK: - negative cases

    func test_returns_nil_for_monolingual_english_book() {
        let pages = (0..<14).map { i in
            page(index: i, text: english)
        }
        XCTAssertNil(BilingualLayoutDetector.detect(pageResults: pages))
    }

    func test_returns_nil_when_l1_is_not_classical() {
        // French/English alternation should NOT trip the detector —
        // the L1 gate restricts to grc/la/he to keep false-positive
        // risk down on the (much more common) modern-language case.
        let french = """
            La philosophie est une discipline universitaire qui étudie \
            les questions fondamentales sur la connaissance, la réalité, \
            l'existence, la valeur, la raison et l'esprit humain. \
            Elle se distingue des autres sciences par sa méthode.
            """
        let pages = makePages(
            alternating: [french, english], count: 12, startIndex: 2
        )
        XCTAssertNil(BilingualLayoutDetector.detect(pageResults: pages))
    }

    func test_returns_nil_when_alternation_breaks() {
        // Long runs of same-language pages — common in a normal
        // book that quotes Latin in a chapter. Alternation rate
        // falls well below the 0.80 gate.
        var pages: [PageObservations] = []
        let scripts = [latin, latin, latin, latin, latin, latin,
                       english, english, english, english, english,
                       english, latin, english, latin, english]
        for (i, s) in scripts.enumerated() {
            pages.append(page(index: i, text: s))
        }
        XCTAssertNil(BilingualLayoutDetector.detect(pageResults: pages))
    }

    func test_returns_nil_for_too_few_pages() {
        let pages = makePages(
            alternating: [latin, english], count: 4, startIndex: 0
        )
        XCTAssertNil(BilingualLayoutDetector.detect(pageResults: pages))
    }

    // MARK: - helpers

    private func page(index: Int, text: String) -> PageObservations {
        PageObservations(
            pageIndex: index,
            pageBounds: CGSize(width: 612, height: 792),
            observations: [
                TextObservation(
                    text: text,
                    confidence: 0.95,
                    box: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
                )
            ]
        )
    }

    private func makePages(
        alternating scripts: [String], count: Int, startIndex: Int
    ) -> [PageObservations] {
        (0..<count).map { i in
            page(index: startIndex + i, text: scripts[i % scripts.count])
        }
    }

    private let latin = """
        Gallia est omnis divisa in partes tres, quarum unam incolunt \
        Belgae, aliam Aquitani, tertiam qui ipsorum lingua Celtae, \
        nostra Galli appellantur. Hi omnes lingua, institutis, legibus \
        inter se differunt. Gallos ab Aquitanis Garumna flumen, a Belgis \
        Matrona et Sequana dividit.
        """

    private let english = """
        All Gaul is divided into three parts, one of which the Belgae \
        inhabit, the Aquitani another, those who in their own language \
        are called Celts, in ours Gauls, the third. All these differ \
        from each other in language, customs and laws. The river Garonne \
        separates the Gauls from the Aquitani.
        """

    private let greek = """
        ἀνθρώπων ἔργα καὶ λόγοι παντοδαποὶ τυγχάνουσιν, ὧν ἕκαστος ἢ \
        τιμῆς ἢ ἀδοξίας μέτοχός ἐστιν, ὥσπερ ἐν πᾶσι τοῖς πράγμασιν ἡ \
        φύσις ἀνθρωπίνη πρὸς τὸ καλὸν ὁρμᾷ. ταῦτα δὴ νοοῦντες οἱ παλαιοὶ \
        διηγοῦντο πρὸς τοὺς νέους τὰ τῶν προγόνων κατορθώματα.
        """
}
