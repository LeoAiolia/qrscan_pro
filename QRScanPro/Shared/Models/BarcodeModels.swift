import Foundation

/// 应用支持的码制；不再保留 .unknown，识别器遇到不支持的码制直接丢弃。
enum BarcodeKind: String, Codable, CaseIterable, Identifiable {
    case qr
    case ean13
    case ean8
    case upce
    case code128
    case code39
    case pdf417
    case aztec
    case dataMatrix

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qr:
            return "QR Code"
        case .ean13:
            return "EAN-13"
        case .ean8:
            return "EAN-8"
        case .upce:
            return "UPC-E"
        case .code128:
            return "Code 128"
        case .code39:
            return "Code 39"
        case .pdf417:
            return "PDF417"
        case .aztec:
            return "Aztec"
        case .dataMatrix:
            return "Data Matrix"
        }
    }

    /// 二维码族（vs 一维条形码），用于历史筛选。
    var isMatrixCode: Bool {
        switch self {
        case .qr, .pdf417, .aztec, .dataMatrix:
            return true
        case .ean13, .ean8, .upce, .code128, .code39:
            return false
        }
    }
}

/// 扫码来源；生成结果已独立到 GeneratedRecord，不再混入此处。
enum ScanSource: String, Codable, CaseIterable, Identifiable {
    case camera
    case image
    /// 通过系统分享面板（Share Extension）从其他 App 接收。
    case shared

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .camera:
            return "相机"
        case .image:
            return "图片"
        case .shared:
            return "分享"
        }
    }
}

/// 识别器（相机 / 图片）输出的原始结果；视图层负责包装成 ScanRecord 并入库。
struct RecognizedCode: Equatable {
    let value: String
    let kind: BarcodeKind
    let source: ScanSource

    var url: URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "http", "https":
            return url
        default:
            return nil
        }
    }
}
