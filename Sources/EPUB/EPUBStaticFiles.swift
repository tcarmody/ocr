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
        """
}
