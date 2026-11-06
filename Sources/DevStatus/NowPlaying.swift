import SwiftUI
import AppKit

/// Musica tocando no Spotify, para o grupo "Mac" do Dock.
/// Estado: notificacao distribuida do Spotify (sem permissao). Capa e controles: AppleScript
/// (o macOS pede permissao de Automacao uma vez). A capa vem de i.scdn.co.
@MainActor
final class NowPlaying: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var playing = false
    @Published private(set) var hasTrack = false
    @Published private(set) var duration: Double = 0      // segundos
    @Published private(set) var position: Double = 0
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: Color = Color(white: 0.25)

    private var trackID = ""
    private var tick: Timer?
    private var observer: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            Task { @MainActor in self?.apply(info) }
        }
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.bundleID else { return }
            Task { @MainActor in self?.clear() }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing else { return }
                self.position = min(self.position + 1, self.duration)
            }
        }
        // Se o Spotify ja estiver aberto, pergunta o estado atual.
        if isRunning { refreshFromScript() }
    }

    static let bundleID = "com.spotify.client"
    static let appIcon: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        .map { NSWorkspace.shared.icon(forFile: $0.path) }
    private var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    var progress: Double { duration > 0 ? min(position / duration, 1) : 0 }

    // MARK: Controles

    func playPause() { run("playpause"); playing.toggle() }
    func next() { run("next track") }
    func previous() { run("previous track") }
    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Estado

    private func apply(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" { clear(); return }
        title = info["Name"] as? String ?? title
        artist = info["Artist"] as? String ?? artist
        if let d = Util.num(info["Duration"]) { duration = d / 1000 }
        if let p = Util.num(info["Playback Position"]) { position = p }
        playing = state == "Playing"
        hasTrack = !title.isEmpty
        let id = info["Track ID"] as? String ?? ""
        if id != trackID { trackID = id; loadArtwork() }
    }

    private func clear() {
        hasTrack = false; playing = false
        title = ""; artist = ""; trackID = ""; artwork = nil
    }

    private func refreshFromScript() {
        let src = """
        tell application "Spotify"
            if player state is stopped then return {}
            set t to current track
            return {name of t, artist of t, duration of t, player position, (player state as string), id of t}
        end tell
        """
        guard let d = Self.script(src), d.numberOfItems >= 6 else { return }
        apply([
            "Name": d.atIndex(1)?.stringValue ?? "",
            "Artist": d.atIndex(2)?.stringValue ?? "",
            "Duration": Double(d.atIndex(3)?.int32Value ?? 0),
            "Playback Position": Double(d.atIndex(4)?.stringValue ?? "") ?? 0,
            "Player State": (d.atIndex(5)?.stringValue ?? "").capitalized,
            "Track ID": d.atIndex(6)?.stringValue ?? "",
        ])
    }

    private func loadArtwork() {
        artwork = nil
        guard let s = Self.script("tell application \"Spotify\" to return artwork url of current track")?.stringValue,
              let url = URL(string: s), url.host?.hasSuffix("scdn.co") == true else { return }
        let id = trackID
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data),
                  id == trackID else { return }
            artwork = img
            tint = Self.averageColor(img)
        }
    }

    private func run(_ command: String) {
        _ = Self.script("tell application \"Spotify\" to \(command)")
    }

    private static func script(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err)
    }

    /// Cor media da capa, escurecida, para o fundo do player.
    private static func averageColor(_ img: NSImage) -> Color { averageColor(img, fallback: nil) ?? Color(white: 0.25) }

    /// Cor media escurecida; nil se a imagem falhar ou for quase preta (ex.: video ainda carregando).
    static func averageColor(_ img: NSImage, fallback: Color?) -> Color? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        if Int(px[0]) + Int(px[1]) + Int(px[2]) < 30 { return fallback }
        return Color(red: Double(px[0]) / 255 * 0.75, green: Double(px[1]) / 255 * 0.75, blue: Double(px[2]) / 255 * 0.75)
    }
}

/// Player compacto (capa, titulo, artista, progresso e controles), com a altura de um icone do Dock.
struct NowPlayingView: View {
    @ObservedObject var player: NowPlaying
    let size: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let art = player.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: size * 0.3)).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.1))
                }
            }
            .frame(width: size - 12, height: size - 12)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture { player.openSpotify() }
            .pointerCursor()

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(player.title).font(.system(size: max(10, size * 0.21), weight: .bold)).lineLimit(1)
                        Text(player.artist).font(.system(size: max(9, size * 0.17))).opacity(0.75).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    control("backward.end.fill") { player.previous() }
                    control(player.playing ? "pause.fill" : "play.fill") { player.playPause() }
                    control("forward.end.fill") { player.next() }
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white.opacity(0.9)).frame(width: g.size.width * player.progress)
                    }
                }
                .frame(height: 3)
            }
            .foregroundStyle(.white)
        }
        .padding(6)
        .frame(width: size * 3.4, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [player.tint.opacity(0.95), player.tint.opacity(0.65)],
                                     startPoint: .leading, endPoint: .trailing))
        )
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(.white.opacity(0.15)))
        .animation(.easeInOut(duration: 0.3), value: player.tint)
    }

    private func control(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: max(10, size * 0.2), weight: .semibold))
                .frame(width: size * 0.32, height: size * 0.32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
