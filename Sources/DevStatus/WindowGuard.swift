import AppKit
import ApplicationServices

/// Mantem as janelas dos outros apps acima da barra do Dock (o macOS nao reserva espaco para ela).
/// Usa a API de Acessibilidade: observa janelas criadas, movidas e redimensionadas e encurta
/// as que invadem a barra. Requer permissao de Acessibilidade.
@MainActor
final class WindowGuard {
    /// Topo da barra em coordenadas de Acessibilidade (y cresce para baixo, origem no topo da tela principal).
    var barTop: () -> CGFloat? = { nil }

    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var retry: Timer?
    private(set) var active = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard !active else { return }
        active = true
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            attachAll()
        } else {
            // Espera o usuario conceder a permissao.
            retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self, self.active else { t.invalidate(); return }
                    if AXIsProcessTrusted() { t.invalidate(); self.retry = nil; self.attachAll() }
                }
            }
        }
    }

    func stop() {
        active = false
        retry?.invalidate(); retry = nil
        for (_, obs) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    /// Reaplica em todas as janelas (ex.: a barra mudou de altura).
    func clampAll() {
        guard active, Self.isTrusted else { return }
        for app in regularApps() {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            for w in windows(of: el) { clamp(w) }
        }
    }

    // MARK: Observadores

    private func regularApps() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
    }

    private func attachAll() {
        regularApps().forEach { attach($0.processIdentifier) }
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            let pid = app.processIdentifier
            // Da tempo do app criar a interface antes de observar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self?.attach(pid) } }
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.detach(pid) }
        })
        clampAll()
    }

    private func attach(_ pid: pid_t) {
        guard active, observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, ref)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
        for w in windows(of: app) { clamp(w) }
    }

    private func detach(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    fileprivate func handle(_ element: AXUIElement) {
        guard active else { return }
        clamp(element)
    }

    // MARK: Ajuste da janela

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private func clamp(_ w: AXUIElement) {
        guard let top = barTop(), let screen = NSScreen.screens.first else { return }
        // So janelas normais, fora de tela cheia.
        guard (attr(w, kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String),
              (attr(w, "AXFullScreen") as Bool?) != true,
              let posV: AXValue = attr(w, kAXPositionAttribute), let sizeV: AXValue = attr(w, kAXSizeAttribute) else { return }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posV, .cgPoint, &pos)
        AXValueGetValue(sizeV, .cgSize, &size)
        // So na tela principal (a da barra).
        let midX = pos.x + size.width / 2
        guard midX >= screen.frame.minX, midX <= screen.frame.maxX else { return }
        let limit = top - 4
        guard pos.y + size.height > limit + 1 else { return }
        if pos.y < limit - 120 {
            var newSize = CGSize(width: size.width, height: limit - pos.y)
            if let v = AXValueCreate(.cgSize, &newSize) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
        } else {
            // Janela baixa demais: sobe para caber acima da barra.
            var newPos = CGPoint(x: pos.x, y: max(screen.frame.height - screen.visibleFrame.maxY, limit - size.height))
            if let v = AXValueCreate(.cgPoint, &newPos) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
        }
    }
}

private let axCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else { return }
    let guardian = Unmanaged<WindowGuard>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { guardian.handle(element) }
}
