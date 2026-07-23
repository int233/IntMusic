import Cocoa
import FlutterMacOS
import MediaPlayer

class MainFlutterWindow: NSWindow {
  private var platformController: IntMusicPlatformController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear
    let materialView = NSVisualEffectView()
    materialView.material = .sidebar
    materialView.blendingMode = .behindWindow
    materialView.state = .followsWindowActiveState
    materialView.addSubview(flutterViewController.view)
    flutterViewController.view.frame = materialView.bounds
    flutterViewController.view.autoresizingMask = [.width, .height]

    let hostViewController = NSViewController()
    hostViewController.view = materialView
    hostViewController.addChild(flutterViewController)

    let windowFrame = self.frame
    self.contentViewController = hostViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    configureModernWindow()
    platformController = IntMusicPlatformController(
      messenger: flutterViewController.engine.binaryMessenger,
      window: self
    )

    super.awakeFromNib()
  }

  private func configureModernWindow() {
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    if #available(macOS 11.0, *) {
      titlebarSeparatorStyle = .none
    }
    styleMask.insert(.fullSizeContentView)
    // Treating the full-size Flutter surface as a draggable window background
    // causes AppKit to consume mouse-down events before Flutter can complete
    // taps. Keep dragging confined to the native title bar so Flutter controls
    // continue to receive clicks.
    isMovableByWindowBackground = false
    backgroundColor = .clear
    minSize = NSSize(width: 920, height: 620)
    if frame.width < 1180 || frame.height < 780 {
      setContentSize(NSSize(width: max(frame.width, 1180), height: max(frame.height, 780)))
      center()
    }

    // FlutterView is hosted inside the material view rather than placed beside
    // one. AppKit can render the semantic sidebar material without intercepting
    // Flutter's mouse-button events.
  }

  override func close() {
    orderOut(nil)
  }
}

private final class IntMusicPlatformController: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var statusItem: NSStatusItem?
  private var playPauseItem: NSMenuItem?
  private var playbackState = "stopped"
  private var artworkTask: URLSessionDataTask?
  private var metadataGeneration = 0
  private var windowMetricObservers: [NSObjectProtocol] = []
  private var lastTitlebarSafeInset: CGFloat?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(
      name: "dev.intmusic/platform",
      binaryMessenger: messenger
    )
    self.window = window
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    configureRemoteCommands()
    observeWindowMetrics()
  }

  deinit {
    artworkTask?.cancel()
    for observer in windowMetricObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    MPRemoteCommandCenter.shared().playCommand.removeTarget(self)
    MPRemoteCommandCenter.shared().pauseCommand.removeTarget(self)
    MPRemoteCommandCenter.shared().togglePlayPauseCommand.removeTarget(self)
    MPRemoteCommandCenter.shared().previousTrackCommand.removeTarget(self)
    MPRemoteCommandCenter.shared().nextTrackCommand.removeTarget(self)
    MPRemoteCommandCenter.shared().stopCommand.removeTarget(self)
    MPRemoteCommandCenter.shared().changePlaybackPositionCommand.removeTarget(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      configureStatusItem()
      let titlebarSafeInset = currentTitlebarSafeInset()
      lastTitlebarSafeInset = titlebarSafeInset
      result([
        "systemTray": true,
        "mediaSession": true,
        "nativeBackdrop": true,
        "backgroundPlayback": true,
        "titlebarSafeInset": titlebarSafeInset,
      ])
    case "updatePlayback":
      updatePlayback(call.arguments as? [String: Any] ?? [:])
      result(nil)
    case "updateVolume":
      result(nil)
    case "showWindow":
      showWindow()
      result(nil)
    case "moveToBackground":
      window?.orderOut(nil)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func observeWindowMetrics() {
    guard let window else { return }
    let names: [Notification.Name] = [
      NSWindow.didResizeNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ]
    for name in names {
      let observer = NotificationCenter.default.addObserver(
        forName: name,
        object: window,
        queue: .main
      ) { [weak self] _ in
        DispatchQueue.main.async {
          self?.publishWindowMetricsIfNeeded()
        }
      }
      windowMetricObservers.append(observer)
    }
  }

  private func currentTitlebarSafeInset() -> CGFloat {
    guard let window, let contentView = window.contentView else { return 0 }
    let contentRect = contentView.convert(contentView.bounds, to: nil)
    return max(0, contentRect.maxY - window.contentLayoutRect.maxY)
  }

  private func publishWindowMetricsIfNeeded() {
    let titlebarSafeInset = currentTitlebarSafeInset()
    if let previous = lastTitlebarSafeInset,
       abs(previous - titlebarSafeInset) < 0.5 {
      return
    }
    lastTitlebarSafeInset = titlebarSafeInset
    channel.invokeMethod(
      "windowMetricsChanged",
      arguments: ["titlebarSafeInset": titlebarSafeInset]
    )
  }

  private func configureStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      if #available(macOS 11.0, *) {
        button.image = NSImage(
          systemSymbolName: "music.note.list",
          accessibilityDescription: "IntMusic"
        )
      } else {
        button.image = NSImage(named: "AppIcon")
      }
      button.toolTip = "IntMusic"
    }

    let menu = NSMenu()
    let nowPlaying = NSMenuItem(title: "IntMusic", action: nil, keyEquivalent: "")
    nowPlaying.isEnabled = false
    menu.addItem(nowPlaying)

    let playPause = NSMenuItem(
      title: "Play",
      action: #selector(togglePlayPause),
      keyEquivalent: ""
    )
    playPause.target = self
    menu.addItem(playPause)
    playPauseItem = playPause

    let previous = NSMenuItem(
      title: "Previous",
      action: #selector(previousTrack),
      keyEquivalent: ""
    )
    previous.target = self
    menu.addItem(previous)

    let next = NSMenuItem(
      title: "Next",
      action: #selector(nextTrack),
      keyEquivalent: ""
    )
    next.target = self
    menu.addItem(next)
    menu.addItem(.separator())

    let show = NSMenuItem(
      title: "Show IntMusic",
      action: #selector(showWindowFromMenu),
      keyEquivalent: ""
    )
    show.target = self
    menu.addItem(show)

    let quit = NSMenuItem(
      title: "Quit IntMusic",
      action: #selector(quitApplication),
      keyEquivalent: "q"
    )
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
  }

  private func configureRemoteCommands() {
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.isEnabled = true
    commands.pauseCommand.isEnabled = true
    commands.togglePlayPauseCommand.isEnabled = true
    commands.previousTrackCommand.isEnabled = true
    commands.nextTrackCommand.isEnabled = true
    commands.stopCommand.isEnabled = true
    commands.changePlaybackPositionCommand.isEnabled = true

    commands.playCommand.addTarget { [weak self] _ in
      self?.invoke("play")
      return .success
    }
    commands.pauseCommand.addTarget { [weak self] _ in
      self?.invoke("pause")
      return .success
    }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.invoke("togglePlayPause")
      return .success
    }
    commands.previousTrackCommand.addTarget { [weak self] _ in
      self?.invoke("previous")
      return .success
    }
    commands.nextTrackCommand.addTarget { [weak self] _ in
      self?.invoke("next")
      return .success
    }
    commands.stopCommand.addTarget { [weak self] _ in
      self?.invoke("stop")
      return .success
    }
    commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.invoke("seek", arguments: Int(event.positionTime * 1000))
      return .success
    }
  }

  private func updatePlayback(_ payload: [String: Any]) {
    playbackState = payload["state"] as? String ?? "stopped"
    playPauseItem?.title = playbackState == "playing" ? "Pause" : "Play"
    statusItem?.button?.toolTip = payload["title"] as? String ?? "IntMusic"

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: payload["title"] as? String ?? "IntMusic",
      MPMediaItemPropertyArtist: payload["artist"] as? String ?? "",
      MPMediaItemPropertyAlbumTitle: payload["album"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration:
        Double(payload["durationMs"] as? Int ?? 0) / 1000.0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime:
        Double(payload["positionMs"] as? Int ?? 0) / 1000.0,
      MPNowPlayingInfoPropertyPlaybackRate: playbackState == "playing" ? 1.0 : 0.0,
    ]
    MPNowPlayingInfoCenter.default().playbackState =
      playbackState == "playing" ? .playing :
      playbackState == "paused" ? .paused : .stopped
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info

    artworkTask?.cancel()
    metadataGeneration += 1
    let generation = metadataGeneration
    guard
      let artworkURLString = payload["artworkUrl"] as? String,
      let artworkURL = URL(string: artworkURLString),
      !artworkURLString.isEmpty
    else { return }

    artworkTask = URLSession.shared.dataTask(with: artworkURL) { [weak self] data, _, _ in
      guard
        let self,
        generation == self.metadataGeneration,
        let data,
        let image = NSImage(data: data)
      else { return }
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
        boundsSize: image.size
      ) { _ in image }
      DispatchQueue.main.async {
        guard generation == self.metadataGeneration else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    }
    artworkTask?.resume()
  }

  private func invoke(_ method: String, arguments: Any? = nil) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod(method, arguments: arguments)
    }
  }

  private func showWindow() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func togglePlayPause() {
    invoke(playbackState == "playing" ? "pause" : "play")
  }

  @objc private func previousTrack() {
    invoke("previous")
  }

  @objc private func nextTrack() {
    invoke("next")
  }

  @objc private func showWindowFromMenu() {
    showWindow()
  }

  @objc private func quitApplication() {
    NSApp.terminate(nil)
  }
}
