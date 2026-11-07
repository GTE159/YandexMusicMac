import SwiftUI
import AppKit

/// Modern, friendly macOS dialog displayed when an account without an active Yandex Plus
/// subscription attempts to stream music or when prompted by account settings.
public struct SubscriptionRequiredSheetView: View {
    @Binding public var isPresented: Bool
    @UIState private var authService = AuthService.shared

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Header Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 255 / 255, green: 75 / 255, blue: 43 / 255),
                                Color(red: 255 / 255, green: 65 / 255, blue: 108 / 255)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.red.opacity(0.35), radius: 14, y: 6)

                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 8)

            // Message Body
            VStack(spacing: 8) {
                Text("Требуется Яндекс Плюс")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(YMTheme.fg)

                let userDisplayName = authService.currentUser?.displayName ?? "Ваш аккаунт"
                Text("На аккаунте \(userDisplayName) нет активной подписки Яндекс Плюс.\n\nКлиент YandexMusicMac строго следует политике сервиса Яндекс Музыки. Воспроизведение треков, альбомов и «Моей волны» доступно только подписчикам Яндекс Плюса.")
                    .font(.system(size: 13))
                    .foregroundStyle(YMTheme.fg80)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)

            // Actions
            VStack(spacing: 10) {
                Button {
                    if let url = URL(string: "https://plus.yandex.ru/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Оформить Яндекс Плюс")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 38))

                Button {
                    isPresented = false
                    authService.signOut()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Войти в другой аккаунт (с Плюсом)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 36))

                Button("Закрыть") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(YMTheme.fg40)
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .padding(24)
        .frame(width: 440)
        .background(YMTheme.surface)
    }
}
