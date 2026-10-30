import Foundation

enum QRErrorCorrectionLevel: String, Codable, CaseIterable, Identifiable {
    case low = "L"
    case medium = "M"
    case quartile = "Q"
    case high = "H"

    var id: String { rawValue }
}

enum QRDotShape: String, Codable, CaseIterable, Identifiable {
    case square
    case circle
    case rounded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .square:
            return "方形"
        case .circle:
            return "圆形"
        case .rounded:
            return "圆角"
        }
    }
}

/// 二维码生成的所有可序列化参数；用于 GeneratedRecord 持久化与生成历史回放编辑。
struct GenerateConfig: Codable, Equatable, Hashable {
    var correctionLevel: QRErrorCorrectionLevel
    var foregroundHex: String       // "#RRGGBB"
    var backgroundHex: String       // "#RRGGBB"
    var sizePx: Int
    var marginModules: Int          // 0...10
    var logoData: Data?
    var logoRatio: Double           // 0.10 ~ 0.30
    var dotShape: QRDotShape

    static let `default` = GenerateConfig(
        correctionLevel: .medium,
        foregroundHex: "#000000",
        backgroundHex: "#FFFFFF",
        sizePx: 1024,
        marginModules: 1,
        logoData: nil,
        logoRatio: 0.20,
        dotShape: .square
    )
}
