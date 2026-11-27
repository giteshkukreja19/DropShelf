import Foundation

// Pure filename/type classification; no reads of file contents or network access.
enum ShelfIntelligentNames {
    struct Entry {
        let name: String
        let ext: String
        let directory: Bool
        let text: Bool
        let image: Bool
    }
    static func suggested(_ entries: [Entry]) -> String? {
        // Preserve a single file's original label.
        guard entries.count > 1 else { return nil }
        let categories = Set(entries.map(category))
        return categories.count == 1 ? categories.first : "Mixed Files"
    }
    private static func category(_ entry: Entry) -> String {
        if entry.directory { return "Folders" }
        if entry.text { return "Text Snippets" }
        let ext = entry.ext.lowercased()
        let name = entry.name.lowercased()
        if entry.image || ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "webp", "bmp", "svg"].contains(ext) {
            return name.hasPrefix("screenshot") || name.hasPrefix("screen shot") ? "Screenshots" : "Images"
        }
        if ext == "pdf" { return "PDF Documents" }
        if ["doc", "docx", "rtf", "pages", "txt", "md"].contains(ext) { return "Documents" }
        if ["xlsx", "xls", "csv", "numbers"].contains(ext) { return "Spreadsheets" }
        if ["ppt", "pptx", "key"].contains(ext) { return "Presentations" }
        if ["zip", "rar", "7z", "tar", "gz"].contains(ext) { return "Archives" }
        if ["mp4", "mov", "mkv", "avi", "webm"].contains(ext) { return "Videos" }
        if ["mp3", "wav", "m4a", "flac", "aac"].contains(ext) { return "Audio" }
        if ["swift", "py", "js", "ts", "java", "cpp", "c", "h", "html", "css", "json"].contains(ext) { return "Project Files" }
        return "Files"
    }
}

extension Shelf {
    func displayShelfName(intelligent: Bool) -> String? {
        if let name, !name.isEmpty { return name }
        guard intelligent else { return nil }
        return ShelfIntelligentNames.suggested(items.map {
            .init(name: $0.displayName, ext: $0.fileURL?.pathExtension ?? "", directory: $0.isDirectory, text: $0.type == .text, image: $0.type == .image)
        })
    }
}
