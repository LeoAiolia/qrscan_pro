import CoreGraphics
import Foundation
import ImageIO
import Vision

#if targetEnvironment(simulator)
import CoreImage
#endif

enum ImageRecognitionError: LocalizedError {
    case noBarcode
    case noEnabledKind
    case invalidImage
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBarcode:
            return L10n.t("未在图片中识别到二维码或条形码")
        case .noEnabledKind:
            return L10n.t("请先在设置中启用至少一种码制")
        case .invalidImage:
            return L10n.t("图片无法读取")
        case .requestFailed(let message):
            return String(format: L10n.t("图片识别失败：%@"), message)
        }
    }
}

struct BarcodeImageRecognizer {
    /// 单码识别：取首个匹配 allowedKinds 的结果。
    /// - Parameter orientation: 图片的 EXIF 方向。`UIImage.cgImage` 会丢掉方向信息，
    ///   不传给 Vision 时旋转过的照片里的一维码更容易识别失败。
    func recognize(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        allowedKinds: Set<BarcodeKind>
    ) async throws -> RecognizedCode {
        let codes = try await recognizeAll(cgImage: cgImage, orientation: orientation, allowedKinds: allowedKinds)
        guard let first = codes.first else {
            throw ImageRecognitionError.noBarcode
        }
        return first
    }

    /// 多码识别：返回图片中所有命中 allowedKinds 的结果，供 macOS 批量识别使用。
    func recognizeAll(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        allowedKinds: Set<BarcodeKind>
    ) async throws -> [RecognizedCode] {
        let allowedSymbologies = allowedKinds.compactMap { $0.visionSymbology }
        guard !allowedSymbologies.isEmpty else {
            throw ImageRecognitionError.noEnabledKind
        }

        do {
            return try await detectWithVision(
                cgImage: cgImage,
                orientation: orientation,
                symbologies: allowedSymbologies
            )
        } catch {
            #if targetEnvironment(simulator)
            // 模拟器上 Vision 条码检测走 ML 推理管线，创建 inference context 会失败
            //（com.apple.Vision Code=9 / VNErrorNotImplemented），此处降级到纯 CPU 的
            // CIDetector 识别 QR，保证模拟器可调试；真机行为不受影响。
            if allowedKinds.contains(.qr) {
                await DebugLogger.shared.warning("Vision 识别失败，模拟器降级 CIDetector：\(error.localizedDescription)")
                return detectQRCodesWithCoreImage(cgImage: cgImage)
            }
            #endif
            throw error
        }
    }

    #if targetEnvironment(simulator)
    /// 模拟器专用兜底：CIDetector 仅支持 QR 码。
    private func detectQRCodesWithCoreImage(cgImage: CGImage) -> [RecognizedCode] {
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) else {
            return []
        }

        let features = detector.features(in: CIImage(cgImage: cgImage), options: nil)
        return features.compactMap { feature in
            guard let qrFeature = feature as? CIQRCodeFeature,
                  let message = qrFeature.messageString else {
                return nil
            }
            return RecognizedCode(value: message, kind: .qr, source: .image)
        }
    }
    #endif

    private func detectWithVision(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        symbologies: [VNBarcodeSymbology]
    ) async throws -> [RecognizedCode] {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RecognizedCode], Error>) in
            // continuation 闭包在调用方线程同步执行；调用方是 @MainActor 视图时，
            // 同步 perform 会把大图识别（几百毫秒）压在主线程上卡住 UI，所以挪到后台队列。
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Self.performDetection(cgImage: cgImage, orientation: orientation, symbologies: symbologies)
                )
            }
        }
    }

    /// 同步执行 Vision 条码检测（调用方负责放到后台线程）。
    ///
    /// Vision 的 completion handler 与 perform 的抛错路径可能被重复触发
    ///（尤其处理大图/异常图片失败时），这里只保留第一次结果，
    /// 保证外层 continuation 只 resume 一次，避免 “resume a continuation twice” 崩溃。
    private static func performDetection(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        symbologies: [VNBarcodeSymbology]
    ) -> Result<[RecognizedCode], Error> {
        // 用引用盒子承接回调结果：completion handler 可能被标注为并发闭包，
        // 直接修改捕获的 var 会触发并发检查报错。
        let box = DetectionOutcomeBox()

        let request = VNDetectBarcodesRequest { request, error in
            guard box.outcome == nil else { return }
            if let error {
                box.outcome = .failure(ImageRecognitionError.requestFailed(error.localizedDescription))
                return
            }

            let observations = (request.results as? [VNBarcodeObservation]) ?? []
            // 置信度高的排前面：单码识别取 first 时优先拿到最可靠的那个。
            let codes: [RecognizedCode] = observations
                .sorted { $0.confidence > $1.confidence }
                .compactMap { observation in
                    guard
                        let value = observation.payloadStringValue, !value.isEmpty,
                        let kind = BarcodeKind(symbology: observation.symbology)
                    else {
                        return nil
                    }
                    return RecognizedCode(value: value, kind: kind, source: .image)
                }
            box.outcome = .success(Self.removingDuplicates(codes))
        }
        request.symbologies = symbologies

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if box.outcome == nil {
                box.outcome = .failure(ImageRecognitionError.requestFailed(error.localizedDescription))
            }
        }
        return box.outcome ?? .success([])
    }

    /// 仅在单次 performDetection 内、同一线程上读写（perform 同步回调 completion）。
    private final class DetectionOutcomeBox {
        var outcome: Result<[RecognizedCode], Error>?
    }

    /// Vision 对同一个码偶尔会返回多个重叠的 observation，按「码制 + 内容」去重并保持顺序。
    private static func removingDuplicates(_ codes: [RecognizedCode]) -> [RecognizedCode] {
        var seen = Set<String>()
        return codes.filter { seen.insert("\($0.kind.rawValue)|\($0.value)").inserted }
    }
}

extension BarcodeKind {
    var visionSymbology: VNBarcodeSymbology? {
        switch self {
        case .qr:
            return .qr
        case .ean13:
            return .ean13
        case .ean8:
            return .ean8
        case .upce:
            return .upce
        case .code128:
            return .code128
        case .code39:
            return .code39
        case .pdf417:
            return .pdf417
        case .aztec:
            return .aztec
        case .dataMatrix:
            return .dataMatrix
        }
    }

    /// 不支持的码制返回 nil；调用方决定是丢弃还是上报。
    init?(symbology: VNBarcodeSymbology) {
        switch symbology {
        case .qr:
            self = .qr
        case .ean13:
            self = .ean13
        case .ean8:
            self = .ean8
        case .upce:
            self = .upce
        case .code128:
            self = .code128
        case .code39:
            self = .code39
        case .pdf417:
            self = .pdf417
        case .aztec:
            self = .aztec
        case .dataMatrix:
            self = .dataMatrix
        default:
            return nil
        }
    }
}
