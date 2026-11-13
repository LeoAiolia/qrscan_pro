import ImageIO
import OSLog
import UIKit
import UniformTypeIdentifiers
import Vision

/// 系统分享面板中的「QRScan Pro」入口：提取分享的链接 / 文本 / 图片（识别其中的码），
/// 再写入 App Group 收件箱（SharedInbox），由主 App 回到前台时读取、入库并打开扫码详情。
final class ShareViewController: UIViewController {
    private var handled = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !handled else { return }
        handled = true
        Task { @MainActor in
            await process()
        }
    }

    // MARK: - Processing

    @MainActor
    private func process() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        guard let payload = await buildPayload(from: providers) else {
            Self.logger.error("无可用载荷，取消分享")
            showFeedback(tr("未识别到可保存的内容"), systemImage: "xmark.circle.fill")
            try? await Task.sleep(nanoseconds: Self.feedbackDuration)
            extensionContext?.cancelRequest(withError: ShareError.noContent)
            return
        }
        // 先写入 App Group 收件箱，主 App 激活时读取；即使拉起失败，内容也不会丢。
        let saved = SharedInbox.append(payload)
        Self.logger.info("写入收件箱结果：\(saved, privacy: .public)")
        // 尝试经 UIScene.open 拉起主 App（UIApplication.open 在此环境已不可用）；主 App 激活时会读取收件箱。
        if saved, let wakeURL = URL(string: "\(SharePayload.scheme)://\(SharePayload.host)") {
            let opened = await openHostApp(wakeURL)
            Self.logger.info("UIScene.open 结果：\(opened, privacy: .public)")
            if opened {
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
        }
        if saved {
            showFeedback(tr("已保存，打开 QRScan Pro 查看"), systemImage: "checkmark.circle.fill")
        } else {
            showFeedback(tr("保存失败，请重试"), systemImage: "xmark.circle.fill")
        }
        try? await Task.sleep(nanoseconds: Self.feedbackDuration)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static let feedbackDuration: UInt64 = 1_200_000_000

    /// 扩展内的简易反馈：居中显示图标 + 文案。
    private func showFeedback(_ message: String, systemImage: String) {
        let imageView = UIImageView(image: UIImage(systemName: systemImage))
        imageView.tintColor = .label
        imageView.contentMode = .scaleAspectFit
        let label = UILabel()
        label.text = message
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .headline)
        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            imageView.heightAnchor.constraint(equalToConstant: 44),
            imageView.widthAnchor.constraint(equalToConstant: 44),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func buildPayload(from providers: [NSItemProvider]) async -> SharePayload? {
        for provider in providers {
            Self.logger.info("收到分享附件，类型：\(provider.registeredTypeIdentifiers.joined(separator: ","), privacy: .public)")
        }
        // 优先级：网页链接 > 文本 > 图片 / 文件（网页分享常同时带缩略图，不应抢占链接）。
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let url = await loadURL(from: provider) {
            if url.isFileURL {
                // 「其他应用打开」常以文件形式传递图片：读取后识别其中的码。
                if let data = try? Data(contentsOf: url), let (value, kind) = Self.recognizeBarcode(inImageData: data) {
                    return SharePayload(value: value, kindRawValue: kind.rawValue)
                }
                Self.logger.warning("文件分享未识别到码")
            } else {
                return SharePayload(
                    value: url.absoluteString,
                    kindRawValue: BarcodeKind.qr.rawValue
                )
            }
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
           let text = await loadText(from: provider), !text.isEmpty {
            return SharePayload(
                value: text,
                kindRawValue: BarcodeKind.qr.rawValue
            )
        }
        // 图片，或任意 public.data（微信「其他应用打开」可能以通用文件类型传递）：读取数据后识别。
        for provider in providers {
            guard
                provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
                let data = await loadData(from: provider),
                let (value, kind) = Self.recognizeBarcode(inImageData: data)
            else { continue }
            return SharePayload(value: value, kindRawValue: kind.rawValue)
        }
        // 兜底：部分来源只把文字放在 NSExtensionItem 的 attributedContentText 里。
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        if let text = items.compactMap({ $0.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return SharePayload(value: text, kindRawValue: BarcodeKind.qr.rawValue)
        }
        Self.logger.error("未能从分享内容中提取有效数据")
        return nil
    }

    private static let logger = Logger(subsystem: "com.pz.qrscanpro.share", category: "share")

    private func loadData(from provider: NSItemProvider) async -> Data? {
        let typeIdentifier = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            ? UTType.image.identifier : UTType.data.identifier
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                continuation.resume(returning: item as? URL)
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text)
            }
        }
    }

    private static func recognizeBarcode(inImageData data: Data) -> (String, BarcodeKind)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        for observation in request.results ?? [] {
            guard let value = observation.payloadStringValue, !value.isEmpty else { continue }
            return (value, Self.kind(for: observation.symbology))
        }
        return nil
    }

    private static func kind(for symbology: VNBarcodeSymbology) -> BarcodeKind {
        switch symbology {
        case .qr, .microQR:
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
        default:
            return .qr
        }
    }

    // MARK: - Open host app

    @MainActor
    private func openHostApp(_ url: URL) async -> Bool {
        guard let scene = view.window?.windowScene else {
            Self.logger.error("未取得 windowScene")
            return false
        }
        return await withCheckedContinuation { continuation in
            scene.open(url, options: nil) { success in
                continuation.resume(returning: success)
            }
        }
    }

    private func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private enum ShareError: Error {
        case noContent
    }
}
