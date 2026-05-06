import XCTest
import Foundation
@testable import EPUB

/// Tests for the JSON parser only — `validate(epubURL:)` shells out
/// to `epubcheck` which we don't bundle with tests; that path is
/// exercised manually via the editor's Validate EPUB sheet.
final class EPUBValidatorTests: XCTestCase {

    // MARK: - Empty / passing report

    func test_parseReport_empty_messages_returns_passed() throws {
        let json = #"""
        {
          "messages": []
        }
        """#
        let report = try EPUBValidator.parseReport(jsonData: json.data(using: .utf8)!)
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.messages.isEmpty)
        XCTAssertTrue(report.counts.isEmpty)
    }

    func test_parseReport_warnings_only_still_passes() throws {
        let json = #"""
        {
          "messages": [
            { "ID": "OPF-073", "severity": "WARNING", "message": "minor",
              "locations": [] }
          ]
        }
        """#
        let report = try EPUBValidator.parseReport(jsonData: json.data(using: .utf8)!)
        XCTAssertTrue(report.passed,
            "warning-only reports should still pass; only ERROR/FATAL fail")
        XCTAssertEqual(report.counts[.warning], 1)
    }

    // MARK: - Failing reports

    func test_parseReport_with_error_marks_failed() throws {
        let json = #"""
        {
          "messages": [
            { "ID": "RSC-005", "severity": "ERROR",
              "message": "Required attribute missing",
              "locations": [
                { "path": "OEBPS/chapter-001.xhtml", "line": 42, "column": 5 }
              ]
            }
          ]
        }
        """#
        let report = try EPUBValidator.parseReport(jsonData: json.data(using: .utf8)!)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.messages.count, 1)
        XCTAssertEqual(report.messages[0].severity, .error)
        XCTAssertEqual(report.messages[0].code, "RSC-005")
        XCTAssertEqual(report.messages[0].path, "OEBPS/chapter-001.xhtml")
        XCTAssertEqual(report.messages[0].line, 42)
        XCTAssertEqual(report.counts[.error], 1)
    }

    func test_parseReport_fatal_severity_marks_failed() throws {
        let json = #"""
        {
          "messages": [
            { "ID": "PKG-001", "severity": "FATAL",
              "message": "Unable to read file", "locations": [] }
          ]
        }
        """#
        let report = try EPUBValidator.parseReport(jsonData: json.data(using: .utf8)!)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.messages[0].severity, .fatal)
    }

    // MARK: - Sorting

    func test_parseReport_sorts_by_severity_then_path_then_line() throws {
        let json = #"""
        {
          "messages": [
            { "ID": "OPF-073", "severity": "WARNING", "message": "warn1",
              "locations": [{ "path": "a.xhtml", "line": 10 }] },
            { "ID": "RSC-005", "severity": "ERROR", "message": "err1",
              "locations": [{ "path": "b.xhtml", "line": 5 }] },
            { "ID": "RSC-005", "severity": "ERROR", "message": "err2",
              "locations": [{ "path": "a.xhtml", "line": 20 }] },
            { "ID": "RSC-005", "severity": "ERROR", "message": "err3",
              "locations": [{ "path": "a.xhtml", "line": 5 }] }
          ]
        }
        """#
        let report = try EPUBValidator.parseReport(jsonData: json.data(using: .utf8)!)
        // Errors come before warnings; within errors, a.xhtml:5 →
        // a.xhtml:20 → b.xhtml:5; warning trails.
        XCTAssertEqual(report.messages.count, 4)
        XCTAssertEqual(report.messages[0].message, "err3")  // a.xhtml:5
        XCTAssertEqual(report.messages[1].message, "err2")  // a.xhtml:20
        XCTAssertEqual(report.messages[2].message, "err1")  // b.xhtml:5
        XCTAssertEqual(report.messages[3].message, "warn1") // warning last
    }

    // MARK: - Robustness

    func test_parseReport_unknown_severity_falls_back_to_info() throws {
        let json = #"""
        {
          "messages": [
            { "ID": "X", "severity": "BANANA", "message": "?", "locations": [] }
          ]
        }
        """#
        let report = try EPUBValidator.parseReport(jsonData: json.data(using: .utf8)!)
        XCTAssertEqual(report.messages[0].severity, .info)
    }

    func test_parseReport_missing_locations_keeps_path_nil() throws {
        let json = #"""
        {
          "messages": [
            { "ID": "X", "severity": "ERROR", "message": "no location" }
          ]
        }
        """#
        let report = try EPUBValidator.parseReport(jsonData: json.data(using: .utf8)!)
        XCTAssertEqual(report.messages.count, 1)
        XCTAssertNil(report.messages[0].path)
        XCTAssertNil(report.messages[0].line)
    }

    func test_parseReport_malformed_json_throws() {
        let bad = "not json at all"
        XCTAssertThrowsError(
            try EPUBValidator.parseReport(jsonData: bad.data(using: .utf8)!)
        ) { error in
            guard let validatorError = error as? EPUBValidator.ValidatorError else {
                XCTFail("expected ValidatorError")
                return
            }
            if case .malformedOutput = validatorError {} else {
                XCTFail("expected malformedOutput, got \(validatorError)")
            }
        }
    }

    func test_parseReport_top_level_array_throws() {
        let bad = "[]"
        XCTAssertThrowsError(
            try EPUBValidator.parseReport(jsonData: bad.data(using: .utf8)!)
        )
    }

    func test_parseReport_missing_messages_key_returns_empty_passed() throws {
        let json = #"""
        { "checker": { "name": "epubcheck" } }
        """#
        let report = try EPUBValidator.parseReport(jsonData: json.data(using: .utf8)!)
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.messages.isEmpty)
    }
}
