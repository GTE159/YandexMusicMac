import SwiftUI
import AppKit
import WebKit

/// Native macOS authentication screen with automatic OAuth token interception
/// and explicit WebKit process teardown upon login completion.
public struct LoginView: View {
    @UIState private var authService = AuthService.shared
    @UIState private var manualInput: String = ""
    @UIState private var showOAuthSheet: Bool = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                // Header & Logo
                VStack(spacing: 12) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)

                    Text("Яндекс Музыка")
                        .font(.system(size: 22, weight: .bold))

                    Text("Нативный клиент для macOS Apple Silicon")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Error display banner
                if let error = authService.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 440)
                }

                VStack(spacing: 18) {
                    // MARK: - Способ 1: Автоматический вход через окно OAuth
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Способ 1. Быстрый вход через Яндекс ID")
                            .font(.system(size: 13, weight: .semibold))

                        VStack(spacing: 8) {
                            Button {
                                authService.errorMessage = nil
                                showOAuthSheet = true
                            } label: {
                                HStack {
                                    Image(systemName: "person.badge.key.fill")
                                    Text("Войти через окно OAuth")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .disabled(authService.isAuthenticating)

                            Button {
                                authService.openOAuthInBrowser()
                            } label: {
                                HStack {
                                    Image(systemName: "safari")
                                    Text("Открыть страницу авторизации в браузере")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(authService.isAuthenticating)
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    // MARK: - Способ 2: Ручной ввод токена или ссылки
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Способ 2. Ввод токена или ссылки редиректа")
                            .font(.system(size: 13, weight: .semibold))

                        Text("Вставьте OAuth-токен (y0_...) или скопируйте адресную строку из браузера после входа")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField("Токен или URL редиректа", text: $manualInput)
                                .textFieldStyle(.roundedBorder)
                                .disabled(authService.isAuthenticating)

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
                            .buttonStyle(.bordered)
                            .help("Вставить из буфера обмена")
                            .disabled(authService.isAuthenticating)
                        }

                        Button {
                            let tokenToSubmit = manualInput
                            manualInput = ""
                            Task {
                                await authService.submitManualToken(tokenToSubmit)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Подтвердить и войти")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.regular)
                        .disabled(manualInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authService.isAuthenticating)
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxWidth: 440)

                if authService.isAuthenticating {
                    ProgressView("Проверка сессии через api.music.yandex.net...")
                        .progressViewStyle(.circular)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 420, minHeight: 360)
        .sheet(isPresented: $showOAuthSheet) {
            OAuthSheetView(isPresented: $showOAuthSheet) { token in
                showOAuthSheet = false
                Task {
                    await authService.submitManualToken(token)
                }
            }
        }
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

            if let url = URL(string: "\(AuthService.oauthURLString)&force_confirm=yes") {
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
        private var urlObservation: NSKeyValueObservation?
        private var hasExtractedToken = false

        init(parent: OAuthInterceptionWebView) {
            self.parent = parent
        }

        func startObserving(webView: WKWebView) {
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor [weak self] in
                    guard let self = self, !self.hasExtractedToken else { return }
                    if let urlString = wv.url?.absoluteString {
                        self.interceptIfNeeded(urlString, webView: wv)
                    }
                }
            }
        }

        func stopObserving() {
            urlObservation?.invalidate()
            urlObservation = nil
        }

        private func interceptIfNeeded(_ urlString: String, webView: WKWebView?) {
            guard !hasExtractedToken else { return }
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

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if let urlString = navigationAction.request.url?.absoluteString {
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
