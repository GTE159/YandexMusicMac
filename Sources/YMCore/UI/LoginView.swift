import SwiftUI
import AppKit
import WebKit
import CoreImage

// MARK: - Login Methods

private enum LoginMethod: String, CaseIterable, Identifiable {
    case deviceCode
    case oauthWindow
    case manualToken

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deviceCode: return "Код устройства"
        case .oauthWindow: return "Окно Яндекс ID"
        case .manualToken: return "Токен"
        }
    }

    var compactTitle: String {
        switch self {
        case .deviceCode: return "Устройство"
        case .oauthWindow: return "Яндекс ID"
        case .manualToken: return "Токен"
        }
    }

    var iconName: String {
        switch self {
        case .deviceCode: return "laptopcomputer.and.iphone"
        case .oauthWindow: return "person.badge.key.fill"
        case .manualToken: return "key.fill"
        }
    }
}

/// Native macOS authentication screen supporting OAuth Device Flow ("as device"),
/// ephemeral WKWebView Yandex ID sign-in with automatic `invalid_scope` fallback, and manual token entry.
public struct LoginView: View {
    @UIState private var authService = AuthService.shared
    @UIState private var selectedMethod: LoginMethod = .deviceCode
    @UIState private var manualInput: String = ""
    @UIState private var showOAuthSheet: Bool = false
    @UIState private var isQRVisible: Bool = false
    @UIState private var didCopyCode: Bool = false
    @UIState private var copyResetTask: Task<Void, Never>? = nil
    @Namespace private var tabNamespace

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 22) {
                // Header & Logo with soft accent glow (window draggable)
                headerSection

                // Error display banner (only outside device flow internal errors to avoid duplicate banners)
                if let error = authService.errorMessage, selectedMethod != .deviceCode {
                    errorBanner(error)
                }

                // Single Modern Auth Card with 3 Modes
                VStack(alignment: .leading, spacing: 18) {
                    methodSwitcher

                    Divider()
                        .overlay(YMTheme.border)

                    switch selectedMethod {
                    case .deviceCode:
                        deviceCodeTab
                    case .oauthWindow:
                        oauthWindowTab
                    case .manualToken:
                        manualTokenTab
                    }
                }
                .padding(20)
                .frame(maxWidth: 460)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(YMTheme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(YMTheme.border, lineWidth: 1)
                        )
                        .shadow(color: YMTheme.shadowColor, radius: 10, y: 3)
                )

                if authService.isAuthenticating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Проверка сессии через api.music.yandex.net...")
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg60)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .ymScreenBackground()
        .frame(minWidth: 440, minHeight: 320)
        .onAppear {
            if selectedMethod == .deviceCode && authService.deviceAuthState == .idle && !authService.isAuthenticating {
                authService.startDeviceAuth()
            }
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
            authService.cancelDeviceAuth()
        }
        .onChange(of: selectedMethod) { oldValue, newValue in
            if oldValue == .deviceCode && newValue != .deviceCode {
                authService.cancelDeviceAuth()
                isQRVisible = false
                didCopyCode = false
            } else if newValue == .deviceCode && authService.deviceAuthState == .idle {
                authService.startDeviceAuth()
            }
        }
        .sheet(isPresented: $showOAuthSheet) {
            OAuthSheetView(isPresented: $showOAuthSheet) { token in
                showOAuthSheet = false
                Task {
                    await authService.submitManualToken(token)
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(YMTheme.accent.opacity(YMTheme.isLight ? 0.16 : 0.22))
                    .frame(width: 88, height: 88)
                    .blur(radius: 16)

                if let appIcon = NSApp?.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 78, height: 78)
                } else {
                    Circle()
                        .fill(YMTheme.surface)
                        .frame(width: 68, height: 68)
                        .overlay(
                            Circle()
                                .strokeBorder(YMTheme.border, lineWidth: 1)
                        )
                        .shadow(color: YMTheme.shadowColor, radius: 12, y: 4)

                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(YMTheme.accent)
                }
            }

            Text("flow~")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(YMTheme.fg)

            Text("Нативный клиент Яндекс Музыки для macOS")
                .font(.subheadline)
                .foregroundStyle(YMTheme.fg60)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .background(YMWindowDragHandle())
    }

    // MARK: - Segmented Method Switcher

    @ViewBuilder
    private var methodSwitcher: some View {
        ViewThatFits(in: .horizontal) {
            segmentedTabsRow(compact: false, scope: "wide")
            segmentedTabsRow(compact: true, scope: "compact")
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(
            Capsule(style: .continuous)
                .fill(YMTheme.surfaceComponent)
                .overlay(Capsule(style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
        )
    }

    @ViewBuilder
    private func segmentedTabsRow(compact: Bool, scope: String) -> some View {
        HStack(spacing: 4) {
            ForEach(LoginMethod.allCases) { method in
                let isSelected = selectedMethod == method
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        selectedMethod = method
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: method.iconName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(compact ? method.compactTitle : method.title)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(isSelected ? Color.black : YMTheme.fg80)
                    .padding(.horizontal, compact ? 10 : 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(YMTheme.accentFill)
                                .matchedGeometryEffect(id: "login_method_capsule_\(scope)", in: tabNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Tab 1: Device Flow

    @ViewBuilder
    private var deviceCodeTab: some View {
        switch authService.deviceAuthState {
        case .idle:
            VStack(spacing: 14) {
                Text("Безопасный вход без встроенного браузера и доступа к сторонним сервисам.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(YMTheme.fg60)
                    .multilineTextAlignment(.center)

                Button {
                    authService.startDeviceAuth()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "laptopcomputer.and.iphone")
                        Text("Получить код")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 38))
            }
            .padding(.vertical, 6)

        case .requestingCode:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Запрашиваем код устройства в Яндекс ID...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(YMTheme.fg80)
                Spacer()
            }
            .padding(.vertical, 18)

        case .awaitingConfirmation(let code, let expiresAt):
            VStack(alignment: .leading, spacing: 14) {
                // 2-step instruction
                VStack(alignment: .leading, spacing: 4) {
                    instructionRow(step: "1", text: "Нажмите кнопку ниже — код скопируется, и откроется страница подтверждения Яндекс ID.")
                    instructionRow(step: "2", text: "Вставьте код (⌘V) и подтвердите устройство flow~.")
                }

                // Prominent clickable code card
                Button {
                    copyCode(code.userCode)
                } label: {
                    HStack(spacing: 12) {
                        Text(code.userCode)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .tracking(4)
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Spacer(minLength: 8)

                        if didCopyCode {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Скопировано")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(YMTheme.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(YMTheme.accent.opacity(0.16)))
                        } else {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(YMTheme.fg60)
                                .padding(7)
                                .background(Circle().fill(YMTheme.surfaceComponent))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(YMTheme.surfaceComponent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(didCopyCode ? YMTheme.accent.opacity(0.55) : YMTheme.border, lineWidth: 1)
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Нажмите, чтобы скопировать код устройства")

                // Primary CTA
                Button {
                    copyCode(code.userCode)
                    if let url = URL(string: code.verificationUrl) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right.square.fill")
                        Text("Скопировать код и открыть \(shortHost(code.verificationUrl))")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 38))

                // Countdown + QR + Refresh
                HStack(spacing: 10) {
                    DeviceCountdownStatusRow(expiresAt: expiresAt)

                    Spacer(minLength: 8)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isQRVisible.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 11, weight: .semibold))
                            Text("QR-код")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(isQRVisible ? YMTheme.accent : YMTheme.fg60)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(isQRVisible ? YMTheme.accent.opacity(0.14) : YMTheme.surfaceComponent)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        didCopyCode = false
                        authService.startDeviceAuth()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Новый код")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(YMTheme.fg60)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(YMTheme.surfaceComponent))
                    }
                    .buttonStyle(.plain)
                }

                // Expandable QR code
                if isQRVisible {
                    HStack {
                        Spacer()
                        DeviceQRCodeView(urlString: code.verificationUrl, size: 132)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                // Minimal scope indicator
                HStack(spacing: 6) {
                    if code.usedMinimalScope {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(YMTheme.accent)
                        Text("Запрашиваются только права доступа к Яндекс Музыке (без Диска и Почты).")
                            .font(.system(size: 11))
                            .foregroundStyle(YMTheme.fg40)
                    } else {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(YMTheme.fg40)
                        Text("Используется стандартный профиль прав клиента Яндекс Музыки.")
                            .font(.system(size: 11))
                            .foregroundStyle(YMTheme.fg40)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

        case .verifyingToken:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Подтверждено! Загружаем профиль...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(YMTheme.fg)
                Spacer()
            }
            .padding(.vertical, 18)

        case .expired:
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Срок действия кода истёк")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(YMTheme.fg)
                }

                Button {
                    authService.startDeviceAuth()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Получить новый код")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 38))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

        case .failed(let message):
            VStack(spacing: 14) {
                errorBanner(message)

                Button {
                    authService.startDeviceAuth()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Повторить")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 38))
            }
        }
    }

    // MARK: - Tab 2: Ephemeral OAuth Window / Default Browser

    @ViewBuilder
    private var oauthWindowTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Войдите через встроенное изолированное окно (данные браузера очищаются сразу после входа) или откройте страницу в браузере по умолчанию.")
                .font(.system(size: 12.5))
                .foregroundStyle(YMTheme.fg60)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button {
                    authService.errorMessage = nil
                    showOAuthSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                        Text("Войти через встроенное окно")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 38))
                .disabled(authService.isAuthenticating)

                Button {
                    authService.openOAuthInBrowser()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "safari")
                        Text("Открыть авторизацию в браузере")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 34))
                .disabled(authService.isAuthenticating)
            }
        }
    }

    // MARK: - Tab 3: Manual Token Entry

    @ViewBuilder
    private var manualTokenTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Вставьте OAuth-токен (y0_...) или скопируйте адресную строку из браузера после входа.")
                .font(.system(size: 12.5))
                .foregroundStyle(YMTheme.fg60)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Токен или URL редиректа", text: $manualInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(YMTheme.fg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(YMTheme.surfaceComponent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(YMTheme.border, lineWidth: 1)
                            )
                    )
                    .disabled(authService.isAuthenticating)
                    .onSubmit {
                        submitManualInputIfReady()
                    }

                Button {
                    if let clipboard = NSPasteboard.general.string(forType: .string) {
                        let extracted = AuthService.extractToken(from: clipboard)
                        manualInput = extracted.isEmpty
                            ? clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                            : extracted
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 34))
                .help("Вставить из буфера обмена")
                .disabled(authService.isAuthenticating)
            }

            Button {
                submitManualInputIfReady()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Подтвердить и войти")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 38))
            .opacity(manualInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1.0)
            .disabled(manualInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.isAuthenticating)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func instructionRow(step: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(step)
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(YMTheme.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(YMTheme.accent.opacity(0.16)))

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(YMTheme.fg80)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(YMTheme.heartRed)
            Text(message)
                .font(.callout)
                .foregroundStyle(YMTheme.heartRed)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(YMTheme.heartRed.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(YMTheme.heartRed.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func submitManualInputIfReady() {
        let tokenToSubmit = manualInput
        guard !tokenToSubmit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !authService.isAuthenticating else { return }
        Task {
            await authService.submitManualToken(tokenToSubmit)
            if authService.isAuthenticated {
                manualInput = ""
            }
        }
    }

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopyCode = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            didCopyCode = false
        }
    }

    private func shortHost(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else {
            return urlString
        }
        let path = url.path == "/" ? "" : url.path
        return "\(host)\(path)"
    }
}

// MARK: - Isolated Countdown Timer Row

private struct DeviceCountdownStatusRow: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let remaining = max(0, Int(ceil(expiresAt.timeIntervalSince(context.date))))
            let minutes = remaining / 60
            let seconds = remaining % 60
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.78)
                Text(String(format: "Ожидаем подтверждения · %d:%02d", minutes, seconds))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(YMTheme.fg60)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - CoreImage QR Code Renderer

private struct DeviceQRCodeView: View {
    let urlString: String
    let size: CGFloat
    @UIState private var qrImage: NSImage? = nil

    var body: some View {
        Group {
            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white)
                    )
                    .shadow(color: YMTheme.shadowColor, radius: 6, y: 2)
            }
        }
        .onAppear {
            if qrImage == nil {
                qrImage = Self.makeQRCodeImage(from: urlString, size: size)
            }
        }
        .onChange(of: urlString) { _, newValue in
            qrImage = Self.makeQRCodeImage(from: newValue, size: size)
        }
    }

    private static func makeQRCodeImage(from string: String, size: CGFloat) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let extent = outputImage.extent
        guard extent.width > 0 && extent.height > 0 else { return nil }
        let scale = max(1, Int(floor((size * 2.0) / extent.width)))
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

// MARK: - Ephemeral OAuth Sheet with Automatic Process Release

private struct OAuthSheetView: View {
    @Binding var isPresented: Bool
    let onTokenReceived: (String) -> Void
    @UIState private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Авторизация Яндекс ID")
                    .font(.headline)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 8)
                }

                Spacer()

                Button("Закрыть") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if let url = AuthService.oauthAuthorizeURL(minimalScope: true, forceConfirm: true) {
                OAuthInterceptionWebView(url: url, isLoading: $isLoading, onTokenExtracted: onTokenReceived)
                    .frame(minWidth: 480, minHeight: 560)
            }
        }
        .frame(width: 520, height: 620)
    }
}

private struct OAuthInterceptionWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    let onTokenExtracted: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Используем nonPersistent() хранилище: нулевой след на диске и гарантированная выгрузка процесса WebContent
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.startObserving(webView: webView)
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
        nsView.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: OAuthInterceptionWebView
        private weak var webView: WKWebView?
        private var urlObservation: NSKeyValueObservation?
        private var hasExtractedToken = false
        private var didFallbackFromMinimalScope = false

        init(parent: OAuthInterceptionWebView) {
            self.parent = parent
        }

        func startObserving(webView: WKWebView) {
            self.webView = webView
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self = self, !self.hasExtractedToken, let urlString = self.webView?.url?.absoluteString else { return }
                    self.interceptIfNeeded(urlString, webView: self.webView)
                }
            }
        }

        func stopObserving() {
            urlObservation?.invalidate()
            urlObservation = nil
            webView = nil
        }

        private func isInvalidScopeError(_ urlString: String) -> Bool {
            if let components = URLComponents(string: urlString) {
                if components.queryItems?.contains(where: { $0.name == "error" && $0.value == "invalid_scope" }) == true {
                    return true
                }
                if let fragment = components.fragment, fragment.contains("error=invalid_scope") {
                    return true
                }
            }
            return urlString.contains("error=invalid_scope")
        }

        private func interceptIfNeeded(_ urlString: String, webView: WKWebView?) {
            guard !hasExtractedToken else { return }

            if isInvalidScopeError(urlString), !didFallbackFromMinimalScope,
               let fallbackURL = AuthService.oauthAuthorizeURL(minimalScope: false, forceConfirm: true) {
                didFallbackFromMinimalScope = true
                webView?.stopLoading()
                webView?.load(URLRequest(url: fallbackURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
                return
            }

            if urlString.contains("access_token=") {
                let token = AuthService.extractToken(from: urlString)
                if !token.isEmpty {
                    hasExtractedToken = true
                    stopObserving()
                    webView?.stopLoading()
                    webView?.loadHTMLString("", baseURL: nil)
                    parent.isLoading = false
                    parent.onTokenExtracted(token)
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            if let urlString = webView.url?.absoluteString {
                interceptIfNeeded(urlString, webView: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if let urlString = navigationAction.request.url?.absoluteString {
                if isInvalidScopeError(urlString), !didFallbackFromMinimalScope,
                   let fallbackURL = AuthService.oauthAuthorizeURL(minimalScope: false, forceConfirm: true) {
                    didFallbackFromMinimalScope = true
                    decisionHandler(.cancel)
                    webView.load(URLRequest(url: fallbackURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
                    return
                }

                if urlString.contains("access_token=") {
                    let token = AuthService.extractToken(from: urlString)
                    if !token.isEmpty {
                        hasExtractedToken = true
                        stopObserving()
                        // Отменяем переход на тяжелый сайт music.yandex.ru — нам нужен только токен из URL!
                        decisionHandler(.cancel)
                        webView.loadHTMLString("", baseURL: nil)
                        parent.isLoading = false
                        parent.onTokenExtracted(token)
                        return
                    }
                }
            }
            decisionHandler(.allow)
        }
    }
}
