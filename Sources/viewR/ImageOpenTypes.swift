import UniformTypeIdentifiers

/// Shared application info and versioning.
enum AppInfo {
    static let version: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.1"
    static let name: String = "<viewR"
    static let formattedName: String = "\(name) v\(version)"
}

/// Shared image content types accepted by viewR.
enum ImageOpenTypes {
    static let contentTypes: [UTType] = [
        .image,
        .jpeg,
        .png,
        .gif,
        .heic,
        .heif,
        .tiff,
        .bmp,
        UTType("org.webmproject.webp")          ?? .image,
        UTType("public.jpeg-2000")              ?? .image,
        UTType("com.adobe.raw-image")           ?? .image,
        UTType("com.canon.cr2-raw-image")       ?? .image,
        UTType("com.canon.cr3-raw-image")       ?? .image,
        UTType("com.nikon.raw-image")           ?? .image,
        UTType("com.sony.raw-image")            ?? .image,
        UTType("com.fuji.raw-image")            ?? .image,
        UTType("com.olympus.raw-image")         ?? .image,
        UTType("com.panasonic.raw-image")       ?? .image,
        UTType("com.leica.raw-image")           ?? .image,
        UTType("com.hasselblad.3fr-raw-image")  ?? .image,
        UTType("com.apple.icns")                ?? .image,
        UTType("com.microsoft.ico")             ?? .image,
        .svg,
    ]
}
