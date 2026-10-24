import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import UIKit

/// 相机预览容器：负责 AVCaptureSession + previewLayer，以及点按对焦 / 卡住重对焦 /
/// 自动缩放的手势与策略。扫描框、对焦框、提示文案都由 SwiftUI 层叠加。
struct LiveScannerContainer: UIViewControllerRepresentable {
    @Binding var isTorchOn: Bool
    let feedback: ScannerFeedback
    /// SwiftUI 层算好的可见扫描框（容器全屏坐标）。折叠屏折痕避让后它不再居中，
    /// 相机识别区必须跟着它走，否则「画出来的框」与「识别区」会错位。
    var scanBoxRect: CGRect
    let onResult: (RecognizedCode) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        ScannerViewController(feedback: feedback, onResult: onResult, onError: onError)
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {
        uiViewController.setTorch(on: isTorchOn)
        uiViewController.setVisibleScanBox(scanBoxRect)
    }

    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: ()) {
        uiViewController.setTorch(on: false)
        uiViewController.teardown()
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let feedback: ScannerFeedback
    private let onResult: (RecognizedCode) -> Void
    private let onError: (String) -> Void
    private let session = AVCaptureSession()
    /// startRunning / stopRunning / 设备配置都是阻塞或需要串行的操作，统一放这个队列，
    /// 保证启停顺序，也保证对焦、缩放、手电筒不会同时 lockForConfiguration。
    private let sessionQueue = DispatchQueue(label: "com.pz.qrscanpro.scanner.session")
    private lazy var focusController = CameraFocusController(sessionQueue: sessionQueue)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var captureDevice: AVCaptureDevice?
    private var isHandlingResult = false
    /// 页面当前是否可见。首次授权时 buildSession() 晚于 viewWillAppear，用它决定构建完成后要不要立即启动。
    private var wantsRunning = false
    /// 长时间无结果时主动重对焦的循环任务。
    private var refocusTask: Task<Void, Never>?
    /// 双指捏合的手势起点倍率。
    private var pinchStartZoom: CGFloat = 1
    /// 「码框诊断」日志的节流时间戳。
    private var lastZoomDiagnosticAt: Date = .distantPast
    /// session 是否已真正跑起来。只有跑起来后预览层才有有效尺寸，坐标换算才可用。
    private var isSessionRunning = false
    /// SwiftUI 层传入的可见扫描框（view 坐标）；nil 时回退为居中方框。
    private var visibleScanBox: CGRect?
    /// iPhone Duo 相机方向协调器（类型 iOS 27.1 才可用，用 Any 持有）。
    private var directionCoordinator: Any?

    init(
        feedback: ScannerFeedback,
        onResult: @escaping (RecognizedCode) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.feedback = feedback
        self.onResult = onResult
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureFeedbackCallbacks()
        configureGestures()
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        // 尺寸 / 方向变化后要重算识别区域，否则旋转屏幕后「画出来的框」与「识别区」会错位。
        updateInterestRect()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        wantsRunning = true
        startSessionIfNeeded()
        startRefocusLoop()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        wantsRunning = false
        stopSessionIfNeeded()
        stopRefocusLoop()
        setTorch(on: false)
    }

    /// 页面销毁时释放 KVO 观察与循环任务。
    func teardown() {
        stopRefocusLoop()
        directionCoordinator = nil
        // 页面销毁才把倍率复位，切 tab 期间保留用户的缩放与手动接管状态。
        focusController.resetForReappear()
        focusController.detach()
    }

    // MARK: - 设备配置

    private func configureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            buildSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] isGranted in
                DispatchQueue.main.async {
                    if isGranted {
                        self?.buildSession()
                    } else {
                        self?.onError(L10n.t("相机权限未授权，请在「设置」中开启相机权限。"))
                    }
                }
            }
        case .denied, .restricted:
            onError(L10n.t("相机权限未授权，请在「设置」中开启相机权限。"))
        @unknown default:
            onError(L10n.t("相机权限状态未知"))
        }
    }

    private func buildSession() {
        guard let device = Self.makeBackCamera() else {
            onError(L10n.t("当前设备不支持相机扫码"))
            return
        }
        captureDevice = device

        var configurationError: Error?
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            // 提高采集分辨率：TN2325 建议用「足够的分辨率 + 阈值内的缩放」给解码器更多真实像素。
            // 必须在加入 input 之后判断，此时 session 才知道设备能力。
            session.sessionPreset = Self.bestSessionPreset(for: session)

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                metadataOutput = output
            }

            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = view.bounds
            view.layer.insertSublayer(previewLayer, at: 0)
            self.previewLayer = previewLayer
        } catch {
            configurationError = error
        }
        session.commitConfiguration()

        if let configurationError {
            onError(String(format: L10n.t("相机初始化失败：%@"), configurationError.localizedDescription))
            return
        }

        configureMetadataObjectTypes()
        focusController.attach(device: device)
        logCameraConfiguration(device: device)
        setUpDirectionCoordinator()

        // 首次授权时本方法晚于 viewWillAppear，这里补一次启动，否则预览会一直黑屏。
        startSessionIfNeeded()
    }

    /// 优先使用虚拟多摄设备（系统可在镜头间自动切换，近距离合焦明显更好），
    /// 都不可用时回退到默认后置摄像头。
    private static func makeBackCamera() -> AVCaptureDevice? {
        for type in ScannerTuning.preferredBackCameraTypes {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// 依次尝试高分辨率预设，返回第一个当前设备可用的。
    private static func bestSessionPreset(for session: AVCaptureSession) -> AVCaptureSession.Preset {
        for preset in ScannerTuning.preferredSessionPresets where session.canSetSessionPreset(preset) {
            return preset
        }
        return session.sessionPreset
    }

    /// 把「真正参与识别的区域」对齐到界面上画的扫描框。
    ///
    /// TN2325 的 Table 1 指出：同时开启二维码时，一维码只在 `rectOfInterest` 中心附近的
    /// 扫描线上才可能被解出，所以识别区应当与用户被引导放置的位置一致。
    private func updateInterestRect() {
        // 预览层要等 session 真正跑起来才有有效尺寸；在此之前换算会得到退化矩阵
        // （控制台那条 CGAffineTransformInvert: singular matrix）甚至空矩形，
        // 而空矩形等于「哪都不识别」，所以这里直接不动，保持默认的整幅画面。
        guard ScannerTuning.restrictToScanBox else { return }
        guard
            isSessionRunning,
            let previewLayer,
            let metadataOutput,
            view.bounds.width > 0,
            view.bounds.height > 0
        else { return }

        // SwiftUI 层传入的可见框已含折叠屏折痕避让；未传（极早期布局）时回退居中方框。
        let visibleBox = visibleScanBox ?? ScannerTuning.scanBoxRect(in: view.bounds.size)
        let layerRect = ScannerTuning.interestRect(forVisibleBox: visibleBox, in: view.bounds.size)
        let converted = previewLayer.metadataOutputRectConverted(fromLayerRect: layerRect)
        guard converted.width > 0.001, converted.height > 0.001 else { return }
        guard metadataOutput.rectOfInterest != converted else { return }

        metadataOutput.rectOfInterest = converted
        DebugLogger.shared.info(
            "识别区域：layer=\(Self.rectText(layerRect)) → metadata=\(Self.rectText(converted))"
        )
    }

    /// SwiftUI 层更新可见扫描框（折叠姿态变化等）。识别区必须立即跟随，
    /// 否则用户被引导放码的位置和真正识别的区域会错位。
    func setVisibleScanBox(_ rect: CGRect) {
        guard visibleScanBox != rect else { return }
        visibleScanBox = rect
        updateInterestRect()
    }

    // MARK: - 折叠屏相机方向（iPhone Duo）

    /// iPhone Duo 折叠 / 展开会改变「摄像头相对当前屏幕」的方向：半折时后置镜头
    /// 可能折到朝向用户的一侧（拍不到码）。方向协调器在方向变化时回调，
    /// 这里确保始终用「背对屏幕」的镜头——与看着屏幕扫面前的码一致。
    private func setUpDirectionCoordinator() {
        guard #available(iOS 27.1, *) else { return }
        directionCoordinator = AVCaptureDeviceDirectionCoordinator(
            view: view,
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
        ) { [weak self] directions in
            self?.preferBackwardFacingCamera(directions)
        }
    }

    @available(iOS 27.1, *)
    private func preferBackwardFacingCamera(_ directions: AVCaptureDeviceDirectionMap) {
        let backward = directions.backwardFacingDeviceDescriptors

        // 当前镜头仍背对屏幕（普通 iPhone / Duo 正常姿态）→ 不动。
        if let current = captureDevice, backward.contains(where: { $0.uniqueID == current.uniqueID }) {
            return
        }

        // 按扫码偏好挑替换镜头（虚拟多摄优先）；没有可用的就维持现状。
        let candidate = backward.first { ScannerTuning.preferredBackCameraTypes.contains($0.deviceType) }
            ?? backward.first { $0.deviceType == .builtInWideAngleCamera }
            ?? backward.first
        guard
            let candidate,
            let device = AVCaptureDevice(uniqueID: candidate.uniqueID),
            device.uniqueID != captureDevice?.uniqueID
        else { return }

        switchCamera(to: device)
    }

    /// 换用指定镜头：同一 session 不允许并存两个视频输入，先拆旧再装新，
    /// 装不上则整体回滚，避免折叠切换瞬间黑屏。
    private func switchCamera(to device: AVCaptureDevice) {
        let torchWasOn = captureDevice?.torchMode == .on
        sessionQueue.async { [weak self, session] in
            guard let self else { return }
            guard let newInput = try? AVCaptureDeviceInput(device: device) else { return }
            let oldInputs = session.inputs

            session.beginConfiguration()
            oldInputs.forEach { session.removeInput($0) }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                session.commitConfiguration()
            } else {
                oldInputs.forEach { input in
                    if session.canAddInput(input) {
                        session.addInput(input)
                    }
                }
                session.commitConfiguration()
                return
            }

            Task { @MainActor in
                self.captureDevice = device
                self.focusController.attach(device: device)
                self.focusController.syncZoomMirrorWithDevice()
                self.updateInterestRect()
                if torchWasOn {
                    self.setTorch(on: true)
                }
                DebugLogger.shared.info("折叠屏镜头方向变化：已切换到 \(device.localizedName)")
            }
        }
    }

    /// 确认并记录启用的码制。
    ///
    /// `availableMetadataObjectTypes` 只有在 output 接入 session 之后才有值；万一读完是空集合，
    /// `metadataObjectTypes` 会被设成空数组，表现为**完全识别不到任何码**，所以这里显式打点。
    private func configureMetadataObjectTypes() {
        guard let metadataOutput else { return }
        let available = metadataOutput.availableMetadataObjectTypes
        let wanted = ScannerMetadata.supportedTypes.filter { available.contains($0) }
        if !wanted.isEmpty {
            metadataOutput.metadataObjectTypes = wanted
        }
        DebugLogger.shared.info(
            "码制：可用 \(available.count) 种，启用 \(wanted.count) 种"
                + (wanted.isEmpty ? "（警告：为空将完全识别不到）" : "")
        )
    }

    /// 启动相机预览；此时若还没有 input（授权尚未完成）就先返回，等 buildSession() 收尾时再启动。
    private func startSessionIfNeeded() {
        guard wantsRunning, !session.inputs.isEmpty else { return }
        sessionQueue.async { [weak self, session] in
            if !session.isRunning {
                session.startRunning()
            }
            let running = session.isRunning
            // session 跑起来之后预览层才有有效尺寸，这时重算识别区域才是准的。
            Task { @MainActor in
                guard let self else { return }
                self.isSessionRunning = running
                guard running else { return }
                self.configureMetadataObjectTypes()
                self.updateInterestRect()
                self.focusController.syncZoomMirrorWithDevice()
            }
        }
    }

    /// 停止相机预览。这里不能用主线程读到的 isRunning 做判断（start 可能仍在队列里排队），
    /// 交给串行队列保证它一定排在已入队的 start 之后执行。
    private func stopSessionIfNeeded() {
        sessionQueue.async { [weak self, session] in
            if session.isRunning {
                session.stopRunning()
            }
            let running = session.isRunning
            Task { @MainActor in
                self?.isSessionRunning = running
            }
        }
    }

    /// 把决定「识别距离 / 缩放策略」的关键数值一次性打进日志，方便真机调参。
    private func logCameraConfiguration(device: AVCaptureDevice) {
        let format = device.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let switchOvers: String
        if device.constituentDevices.count > 1 {
            switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors
                .map { Self.fixedText(CGFloat(truncating: $0)) }
                .joined(separator: ", ")
        } else {
            switchOvers = "n/a"
        }
        DebugLogger.shared.info(
            "扫码相机：\(device.localizedName) [\(device.deviceType.rawValue)] "
                + "preset=\(session.sessionPreset.rawValue) "
                + "format=\(dimensions.width)x\(dimensions.height) "
                + "zoom=\(Self.fixedText(device.videoZoomFactor))"
                + "(\(Self.fixedText(device.minAvailableVideoZoomFactor))~\(Self.fixedText(device.maxAvailableVideoZoomFactor))) "
                + "upscaleThreshold=\(Self.fixedText(format.videoZoomFactorUpscaleThreshold)) "
                + "switchOver=[\(switchOvers)]"
        )
    }

    // MARK: - 对焦 / 缩放交互

    private func configureFeedbackCallbacks() {
        focusController.onFocusSettled = { [weak self] in
            self?.feedback.markFocusSettled()
        }
        focusController.onZoomChanged = { [weak self] factor in
            guard let self, self.focusController.isManualZoomActive else { return }
            self.feedback.showZoom(factor)
        }
    }

    private func configureGestures() {
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
    }

    /// 点按对焦：把点击位置换算成设备坐标后交给控制器，同时在原位显示对焦框。
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let previewLayer else { return }
        let layerPoint = gesture.location(in: view)
        focusController.focus(atDevicePoint: previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
        feedback.showFocus(at: layerPoint)
    }

    /// 双指捏合手动缩放：一旦操作即接管，本页不再自动缩放。
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartZoom = focusController.beginManualZoom()
        case .changed:
            focusController.updateManualZoom(pinchStartZoom * gesture.scale)
        case .ended, .cancelled, .failed:
            focusController.endManualZoom()
        default:
            break
        }
    }

    /// 长时间没有检测到码就主动重新对焦一次，解决「对着不动就不再对焦」。
    private func startRefocusLoop() {
        stopRefocusLoop()
        refocusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ScannerTuning.refocusCheckInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.focusController.tick(now: Date())
            }
        }
    }

    private func stopRefocusLoop() {
        refocusTask?.cancel()
        refocusTask = nil
    }

    // MARK: - 手电筒

    func setTorch(on: Bool) {
        guard
            let device = captureDevice ?? AVCaptureDevice.default(for: .video),
            device.hasTorch
        else { return }

        let target: AVCaptureDevice.TorchMode = on ? .on : .off
        guard device.torchMode != target else { return }

        // 与对焦 / 缩放共用同一队列，避免互相打断 lockForConfiguration。
        sessionQueue.async { [weak self] in
            do {
                try device.lockForConfiguration()
                device.torchMode = target
                device.unlockForConfiguration()
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    self?.onError(String(format: L10n.t("闪光灯切换失败：%@"), message))
                }
            }
        }
    }

    // MARK: - 识别结果

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let metadata = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first
        else { return }

        // 只要检测到码就刷新「对焦 / 缩放」信号，不受下面的去重窗口影响。
        focusController.noteResult()
        updateAutoZoom(with: metadata.bounds)

        guard !isHandlingResult else {
            return
        }

        guard
            let value = metadata.stringValue,
            let kind = BarcodeKind(metadataType: metadata.type)
        else {
            return
        }

        isHandlingResult = true
        let result = RecognizedCode(value: value, kind: kind, source: .camera)

        DispatchQueue.main.async {
            self.onResult(result)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.isHandlingResult = false
        }
    }

    /// 用识别到的码在「可见区域」里的宽度占比驱动自动缩放。
    ///
    /// 预览层是 `.resizeAspectFill`（画面有裁剪），所以必须先把 metadata 的归一化矩形
    /// 转成 layer 坐标、再与可见 bounds 求交，否则倍率会和你看到的画框对不上。
    private func updateAutoZoom(with metadataBounds: CGRect) {
        guard let previewLayer, previewLayer.bounds.width > 0 else { return }
        let layerRect = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataBounds)
        let visible = layerRect.intersection(previewLayer.bounds)
        guard !visible.isNull, visible.width > 0 else { return }
        let widthRatio = visible.width / previewLayer.bounds.width

        // 调参用的诊断：把原始 metadata 框和换算后的可见占比一起打出来，
        // 便于确认识别区（rectOfInterest）是否影响了 metadata 的坐标约定。
        if ScannerTuning.verboseZoomDiagnostics {
            let now = Date()
            if now.timeIntervalSince(lastZoomDiagnosticAt) >= 1 {
                lastZoomDiagnosticAt = now
                DebugLogger.shared.info(
                    "码框诊断：metadata=(\(Self.fixedText(metadataBounds.minX)),\(Self.fixedText(metadataBounds.minY)),"
                        + "\(Self.fixedText(metadataBounds.width)),\(Self.fixedText(metadataBounds.height))) "
                        + "可见=(\(Self.fixedText(visible.minX)),\(Self.fixedText(visible.minY)),"
                        + "\(Self.fixedText(visible.width)),\(Self.fixedText(visible.height))) "
                        + "宽度占比=\(Self.fixedText(widthRatio)) "
                        + "设备倍率=\(Self.fixedText(self.focusController.deviceRelativeZoom))x "
                        + "镜像倍率=\(Self.fixedText(self.focusController.relativeZoom))x"
                )
            }
        }

        focusController.updateAutoZoom(visibleWidthRatio: widthRatio)
    }

    // MARK: - 文本格式化（日志用）

    private static func fixedText(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private static func rectText(_ rect: CGRect) -> String {
        String(
            format: "(%.2f,%.2f,%.2f,%.2f)",
            Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)
        )
    }
}

enum ScannerMetadata {
    static let supportedTypes: [AVMetadataObject.ObjectType] = [
        .qr,
        .ean13,
        .ean8,
        .upce,
        .code128,
        .code39,
        .pdf417,
        .aztec,
        .dataMatrix
    ]
}

extension BarcodeKind {
    init?(metadataType: AVMetadataObject.ObjectType) {
        switch metadataType {
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
