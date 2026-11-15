import SwiftUI
import AVKit
import AVFoundation

/// Plays a list of audio/video files (mp3, m4a, wav, mp4, mov ...) with next/previous.
final class PlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var index = 0

    let player = AVPlayer()
    let items: [URL]
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(items: [URL], start: Int) {
        self.items = items
        index = min(max(0, start), max(0, items.count - 1))
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self = self else { return }
            self.time = t.seconds.isFinite ? t.seconds : 0
            self.isPlaying = self.player.rate > 0
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self = self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.finished()
        }
        load(index, autoplay: true)
    }

    deinit {
        player.pause()
        if let t = timeObserver { player.removeTimeObserver(t) }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
    }

    var currentURL: URL { items[index] }

    func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    func load(_ i: Int, autoplay: Bool) {
        guard items.indices.contains(i) else { return }
        index = i
        let item = AVPlayerItem(url: items[i])
        let d = item.asset.duration.seconds
        duration = d.isFinite ? d : 0
        time = 0
        player.replaceCurrentItem(with: item)
        if autoplay {
            player.play()
            isPlaying = true
        }
    }

    func toggle() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0 && time >= duration - 0.3 { seek(0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        time = seconds
    }

    func skip(_ delta: Double) {
        seek(min(max(0, time + delta), max(0, duration)))
    }

    func next() {
        if index + 1 < items.count { load(index + 1, autoplay: true) }
    }

    func previous() {
        if time > 3 || index == 0 { seek(0) } else { load(index - 1, autoplay: true) }
    }

    private func finished() {
        if index + 1 < items.count {
            next()
        } else {
            isPlaying = false
            seek(0)
        }
    }
}

struct MediaPlayerView: View {
    let items: [URL]
    var onClose: () -> Void
    @StateObject private var model: PlayerModel

    init(items: [URL], start: Int, onClose: @escaping () -> Void) {
        self.items = items
        self.onClose = onClose
        _model = StateObject(wrappedValue: PlayerModel(items: items, start: start))
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(T("now_playing")).font(.footnote).foregroundColor(.secondary)
                Spacer()
                Button(action: { model.player.pause(); onClose() }) {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.secondary)
                }
            }

            if model.isVideo(model.currentURL) {
                VideoPlayer(player: model.player)
                    .frame(height: 260)
                    .cornerRadius(10)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground))
                    Image(systemName: "music.note").font(.system(size: 80)).foregroundColor(.blue)
                }
                .frame(width: 220, height: 220)
            }

            Text(model.currentURL.lastPathComponent)
                .font(.headline).lineLimit(2).multilineTextAlignment(.center)
            if items.count > 1 {
                Text("\(model.index + 1) / \(items.count)").font(.caption).foregroundColor(.secondary)
            }

            VStack(spacing: 2) {
                Slider(value: Binding(get: { min(model.time, max(1, model.duration)) },
                                      set: { model.seek($0) }),
                       in: 0...max(1, model.duration))
                HStack {
                    Text(format(model.time))
                    Spacer()
                    Text(format(model.duration))
                }
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }

            HStack(spacing: 30) {
                Button(action: { model.previous() }) { Image(systemName: "backward.fill").font(.title2) }
                Button(action: { model.skip(-15) }) { Image(systemName: "gobackward.15").font(.title2) }
                Button(action: { model.toggle() }) {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 54))
                }
                Button(action: { model.skip(15) }) { Image(systemName: "goforward.15").font(.title2) }
                Button(action: { model.next() }) { Image(systemName: "forward.fill").font(.title2) }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .onDisappear { model.player.pause() }
    }

    private func format(_ t: Double) -> String {
        let v = max(0, t.isFinite ? t : 0)
        return String(format: "%d:%02d", Int(v) / 60, Int(v) % 60)
    }
}
