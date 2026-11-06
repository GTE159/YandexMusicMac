import SwiftUI

/// Native macOS Touch Bar integration providing playback controls, current track info, and like button.
public struct YMPlaybackTouchBar: ViewModifier {
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var likesService = LikesService.shared

    public init() {}

    public func body(content: Content) -> some View {
        content
            .touchBar {
                // Previous Button
                Button {
                    audioEngine.previous()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .disabled(audioEngine.currentTrack == nil)

                // Play / Pause Button
                Button {
                    audioEngine.togglePlayPause()
                } label: {
                    Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(audioEngine.currentTrack == nil)

                // Next Button
                Button {
                    audioEngine.next()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .disabled(audioEngine.currentTrack == nil)

                // Current Track Info & Heart
                if let track = audioEngine.currentTrack {
                    Text("\(track.displayTitle) — \(track.artistsString)")
                        .lineLimit(1)

                    Button {
                        Task {
                            await likesService.toggleLike(track: track)
                        }
                    } label: {
                        Image(systemName: likesService.isLiked(trackId: track.id) ? "heart.fill" : "heart")
                    }

                    if audioEngine.isWaveMode {
                        Button {
                            audioEngine.applyWaveTuning(.moreLikeThis)
                        } label: {
                            Image(systemName: "flame.fill")
                        }
                    }
                }
            }
    }
}

public extension View {
    func ymTouchBar() -> some View {
        modifier(YMPlaybackTouchBar())
    }
}
