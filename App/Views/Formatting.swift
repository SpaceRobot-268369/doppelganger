import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        MarkdownReportWriter.byteString(value)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(MarkdownReportWriter.byteString(Int64(bytesPerSecond)))/s"
    }

    static func eta(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    static func middleTruncated(_ path: String, max: Int = 60) -> String {
        guard path.count > max else { return path }
        let keep = (max - 1) / 2
        return "\(path.prefix(keep))…\(path.suffix(keep))"
    }
}
