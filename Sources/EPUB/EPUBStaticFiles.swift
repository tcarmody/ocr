import Foundation

/// Static files whose contents never depend on the book — included once.
enum EPUBStaticFiles {
    /// `mimetype` MUST be the first entry in the ZIP, MUST be stored
    /// uncompressed, and MUST contain exactly the bytes below — no BOM,
    /// no trailing newline.
    static let mimetype = "application/epub+zip"

    /// `META-INF/container.xml` points readers at the OPF.
    static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles>
        </container>
        """

    /// Default stylesheet. Phase 1 keeps this minimal — typography pass
    /// happens later.
    static let bookCSS = """
        body { font-family: Georgia, "Times New Roman", serif; line-height: 1.5; margin: 1em; }
        h1, h2, h3, h4, h5, h6 { font-family: -apple-system, "Helvetica Neue", sans-serif; line-height: 1.2; }
        p { margin: 0 0 0.6em 0; text-indent: 1.2em; }
        p:first-of-type { text-indent: 0; }
        a[epub|type~="noteref"] { vertical-align: super; font-size: 0.75em; }
        aside[epub|type~="footnote"] { display: none; }
        figure { margin: 1em 0; text-align: center; }
        figure img { max-width: 100%; height: auto; }
        figcaption { font-size: 0.85em; font-style: italic; margin-top: 0.4em; }
        table { border-collapse: collapse; margin: 1em auto; }
        th, td { border: 1px solid #ccc; padding: 0.3em 0.5em; text-align: left; vertical-align: top; }
        th { background: #f5f5f5; font-weight: bold; }
        caption { font-size: 0.85em; font-style: italic; margin-bottom: 0.4em; }
        .verse { margin: 1em 0; }
        .verse .line { margin: 0; text-indent: 0; padding-left: 0; }
        .verse .line.indent-1 { padding-left: 1em; }
        .verse .line.indent-2 { padding-left: 2em; }
        .verse .line.indent-3 { padding-left: 3em; }
        .verse .line.indent-4 { padding-left: 4em; }
        .verse .line.indent-5 { padding-left: 5em; }
        .verse .line.indent-6 { padding-left: 6em; }
        .verse .line.indent-7 { padding-left: 7em; }
        .verse .line.indent-8 { padding-left: 8em; }
        """
}
