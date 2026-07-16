import AppKit

enum ClipboardImageReader {
    /// Read PNG image data from the system clipboard. Returns `nil` if the clipboard
    /// does not contain an image.
    static func readFromClipboard() -> Data? {
        let pb = NSPasteboard.general
        if let png = pb.data(forType: .png) {
            return png
        }
        if let tiff = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }
}
