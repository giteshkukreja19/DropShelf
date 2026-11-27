import Foundation
import PDFKit
import Vision

/// Local layout-aware conversion, with Vision OCR for image-only PDFs.
enum PDFWordConverter {
    private static func convertLayout(_ url: URL, cancelled: () -> Bool, appearance: Bool = false) throws -> Data {
        let fm = FileManager.default
        let python = fm.homeDirectoryForCurrentUser.appendingPathComponent(".dropshelf-pdfword/bin/python")
        guard fm.isExecutableFile(atPath: python.path) else {
            throw PDFToolkit.error("Install the DropShelf PDF-to-Word engine first (see setup instructions).")
        }
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let output = root.appendingPathComponent("output.docx")
        let log = root.appendingPathComponent("conversion.log")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = python
        let appearanceScript = #"""
import sys, io
import pymupdf
from docx import Document
from docx.shared import Pt
from docx.enum.section import WD_SECTION_START, WD_ORIENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
out = Document()
with pymupdf.open(sys.argv[1]) as pdf:
    for i, page in enumerate(pdf):
        sec = out.sections[0] if i == 0 else out.add_section(WD_SECTION_START.NEW_PAGE)
        w, h = page.rect.width, page.rect.height
        sec.orientation = WD_ORIENT.LANDSCAPE if w > h else WD_ORIENT.PORTRAIT
        sec.page_width, sec.page_height = Pt(w), Pt(h)
        sec.top_margin = sec.bottom_margin = sec.left_margin = sec.right_margin = Pt(12)
        sec.header_distance = sec.footer_distance = Pt(0)
        p = out.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        f = p.paragraph_format
        f.space_before = f.space_after = Pt(0)
        f.line_spacing = 1.0
        f.keep_with_next = False
        f.keep_together = False
        f.widow_control = False
        scale = min((w-24)/w, (h-40)/h)
        pix = page.get_pixmap(matrix=pymupdf.Matrix(3,3), alpha=False)
        run = p.add_run()
        run.font.size = Pt(1)
        run.add_picture(io.BytesIO(pix.tobytes('png')), width=Pt(w*scale), height=Pt(h*scale))
        if i > 0:
            prev = p._p.getprevious()
            if prev is not None:
                from docx.text.paragraph import Paragraph
                q = Paragraph(prev, p._parent)
                q.paragraph_format.space_before = q.paragraph_format.space_after = Pt(0)
                q.paragraph_format.line_spacing = Pt(1)
out.save(sys.argv[2])
"""#
        let layoutScript = #"""
from pdf2docx import Converter
import sys, zipfile
from docx import Document
c = Converter(sys.argv[1])
try:
    c.convert(sys.argv[2], multi_processing=False, ignore_page_error=False,
              parse_lattice_table=True, parse_stream_table=True)
finally:
    c.close()
with zipfile.ZipFile(sys.argv[2]) as archive:
    if archive.testzip() is not None:
        raise RuntimeError("Invalid Word archive")
doc = Document(sys.argv[2])
if not (doc.paragraphs or doc.tables or doc.inline_shapes):
    raise RuntimeError("Empty Word conversion")
# Recover source span styling only where the exact run text has one unambiguous style.
# Do not guess styles for merged or ambiguous text, or alter the converter's layout.
import pymupdf, re
from collections import defaultdict
from docx.shared import Pt, RGBColor
from docx.text.paragraph import Paragraph
from docx.oxml.ns import qn
styles = defaultdict(set)
def normalized(text):
    return " ".join(text.split())
with pymupdf.open(sys.argv[1]) as source:
    for page in source:
        for block in page.get_text("dict")["blocks"]:
            for line in block.get("lines", []):
                for span in line.get("spans", []):
                    key = normalized(span.get("text", ""))
                    if not key or len(key) < 2:
                        continue
                    font = re.sub(r"^[A-Z]{6}\+", "", span.get("font", ""))
                    size = round(float(span.get("size", 0)), 2)
                    flags = int(span.get("flags", 0))
                    color = int(span.get("color", 0)) & 0xffffff
                    styles[key].add((font, size, bool(flags & 16), bool(flags & 2), color))
for node in doc.element.body.iter(qn("w:p")):
    paragraph = Paragraph(node, doc)
    for run in paragraph.runs:
        if run._r.find(qn("w:drawing")) is not None:
            continue
        candidates = styles.get(normalized(run.text), set())
        if len(candidates) != 1:
            continue
        font, size, bold, italic, color = next(iter(candidates))
        # Known PDF/PostScript family aliases; retain converter font for unknown names
        # unless it has no explicit font, in which case keep the recoverable name.
        aliases = {"Helvetica": "Arial", "Times-Roman": "Times New Roman", "Courier": "Courier New"}
        family = aliases.get(font)
        if family is None:
            for prefix, family_name in (("Helvetica-", "Arial"), ("Times-", "Times New Roman"), ("Courier-", "Courier New"), ("Arial", "Arial"), ("TimesNewRoman", "Times New Roman"), ("Calibri", "Calibri")):
                if font.startswith(prefix):
                    family = family_name
                    break
        if family or (font and run.font.name is None):
            run.font.name = family or font
        if 1 <= size <= 300:
            run.font.size = Pt(size)
        run.bold = bold
        run.italic = italic
        run.font.color.rgb = RGBColor((color >> 16) & 255, (color >> 8) & 255, color & 255)
doc.save(sys.argv[2])
"""#
        process.arguments = ["-c", appearance ? appearanceScript : layoutScript, url.path, output.path]
        process.standardOutput = handle
        process.standardError = handle
        if cancelled() { throw CancellationError() }
        try process.run()
        while process.isRunning {
            if cancelled() {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if cancelled() { throw CancellationError() }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: output), !data.isEmpty else {
            throw PDFToolkit.error("Layout conversion failed. Check that the PDF-to-Word engine is installed and the PDF is readable.")
        }
        return data
    }

    private static func xml(_ text: String) -> String {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            let n = $0.value
            return n == 9 || n == 10 || n == 13 || (n >= 32 && n <= 0xD7FF) || (n >= 0xE000 && n <= 0xFFFD) || n >= 0x10000
        }))
        return clean.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func convert(_ url: URL, cancelled: () -> Bool) throws -> Data {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else {
            throw PDFToolkit.error("Cannot read PDF or PDF is password protected.")
        }
        let hasText = (0..<pdf.pageCount).allSatisfy { index in
            !(pdf.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let mode = UserDefaults.standard.string(forKey: "pdf.wordMode") ?? "automatic"
        if mode == "appearance" || (mode == "automatic" && !hasText) {
            return try convertLayout(url, cancelled: cancelled, appearance: true)
        }
        if hasText { return try convertLayout(url, cancelled: cancelled) }
        var paragraphs: [String] = []
        var foundText = false
        for index in 0..<pdf.pageCount {
            if cancelled() { throw CancellationError() }
            guard let page = pdf.page(at: index) else { throw PDFToolkit.error("Cannot read page \(index + 1).") }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width > 0, bounds.height > 0, bounds.width <= 3000, bounds.height <= 3000,
                      let image = PDFOCR.renderPageImage(page) else { throw PDFToolkit.error("Cannot render page \(index + 1) for OCR.") }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { foundText = true }
            if index > 0 { paragraphs.append("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>") }
            for line in text.components(separatedBy: .newlines) {
                paragraphs.append("<w:p><w:r><w:t xml:space=\"preserve\">\(xml(line))</w:t></w:r></w:p>")
            }
        }
        guard foundText else { throw PDFToolkit.error("No editable text found in this PDF.") }
        if cancelled() { throw CancellationError() }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for folder in ["_rels", "word"] { try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let files = [
            "[Content_Types].xml": header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>",
            "_rels/.rels": header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
            "word/document.xml": header + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + paragraphs.joined() + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>"
        ]
        for (path, contents) in files { try contents.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let output = root.appendingPathComponent("output.docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", output.path, "[Content_Types].xml", "_rels/.rels", "word/document.xml"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PDFToolkit.error("Could not package Word document.") }
        if cancelled() { throw CancellationError() }
        return try Data(contentsOf: output)
    }
}
