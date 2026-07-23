#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <optional>
#include <string>

#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 42;
constexpr UINT kTrayShow = 41001;
constexpr UINT kTrayPlayPause = 41002;
constexpr UINT kTrayPrevious = 41003;
constexpr UINT kTrayNext = 41004;
constexpr UINT kTrayQuit = 41005;

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr int kDwmWindowCornerRound = 2;
constexpr int kDwmSystemBackdropMica = 2;

const std::string* StringArgument(const flutter::EncodableMap& map,
                                  const char* name) {
  auto value = map.find(flutter::EncodableValue(name));
  if (value == map.end()) {
    return nullptr;
  }
  return std::get_if<std::string>(&value->second);
}

}  // namespace

class FlutterWindow::WindowsMediaSession {
 public:
  WindowsMediaSession(HWND window,
                      std::function<void(const char*)> command_callback)
      : command_callback_(std::move(command_callback)) {
    try {
      auto interop = winrt::get_activation_factory<
          winrt::Windows::Media::SystemMediaTransportControls,
          ISystemMediaTransportControlsInterop>();
      winrt::check_hresult(interop->GetForWindow(
          window,
          winrt::guid_of<
              winrt::Windows::Media::SystemMediaTransportControls>(),
          winrt::put_abi(controls_)));
      controls_.IsEnabled(true);
      controls_.IsPlayEnabled(true);
      controls_.IsPauseEnabled(true);
      controls_.IsPreviousEnabled(true);
      controls_.IsNextEnabled(true);
      controls_.IsStopEnabled(true);
      button_token_ = controls_.ButtonPressed(
          [this](
              const auto&,
              const winrt::Windows::Media::
                  SystemMediaTransportControlsButtonPressedEventArgs& args) {
            using Button =
                winrt::Windows::Media::SystemMediaTransportControlsButton;
            switch (args.Button()) {
              case Button::Play:
                command_callback_("play");
                break;
              case Button::Pause:
                command_callback_("pause");
                break;
              case Button::Previous:
                command_callback_("previous");
                break;
              case Button::Next:
                command_callback_("next");
                break;
              case Button::Stop:
                command_callback_("stop");
                break;
              default:
                break;
            }
          });
    } catch (...) {
      controls_ = nullptr;
    }
  }

  ~WindowsMediaSession() {
    if (controls_) {
      controls_.ButtonPressed(button_token_);
    }
  }

  bool available() const { return static_cast<bool>(controls_); }

  void Update(const flutter::EncodableMap& payload) {
    if (!controls_) {
      return;
    }
    try {
      using Status =
          winrt::Windows::Media::MediaPlaybackStatus;
      const auto* state = StringArgument(payload, "state");
      controls_.PlaybackStatus(
          state && *state == "playing"
              ? Status::Playing
              : state && *state == "paused" ? Status::Paused
                                               : Status::Stopped);

      auto updater = controls_.DisplayUpdater();
      updater.Type(winrt::Windows::Media::MediaPlaybackType::Music);
      auto music = updater.MusicProperties();
      if (const auto* title = StringArgument(payload, "title")) {
        music.Title(winrt::to_hstring(*title));
      }
      if (const auto* artist = StringArgument(payload, "artist")) {
        music.Artist(winrt::to_hstring(*artist));
      }
      if (const auto* album = StringArgument(payload, "album")) {
        music.AlbumTitle(winrt::to_hstring(*album));
      }
      updater.Update();
    } catch (...) {
      // System presentation is best-effort and must not affect playback.
    }
  }

 private:
  std::function<void(const char*)> command_callback_;
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_token_{};
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  ConfigureNativeBackdrop();
  ConfigurePlatformChannel();
  media_session_ = std::make_unique<WindowsMediaSession>(
      GetHandle(), [this](const char* command) { InvokeDartCommand(command); });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  media_session_.reset();
  platform_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_CLOSE:
      ShowWindow(hwnd, SW_HIDE);
      return 0;
    case kTrayCallbackMessage:
      if (lparam == WM_LBUTTONDBLCLK) {
        ShowMainWindow();
      } else if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
        ShowTrayMenu();
      }
      return 0;
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kTrayShow:
          ShowMainWindow();
          return 0;
        case kTrayPlayPause:
          InvokeDartCommand("togglePlayPause");
          return 0;
        case kTrayPrevious:
          InvokeDartCommand("previous");
          return 0;
        case kTrayNext:
          InvokeDartCommand("next");
          return 0;
        case kTrayQuit:
          RemoveTrayIcon();
          DestroyWindow(hwnd);
          PostQuitMessage(0);
          return 0;
      }
      break;
    case WM_APPCOMMAND:
      switch (GET_APPCOMMAND_LPARAM(lparam)) {
        case APPCOMMAND_MEDIA_PLAY_PAUSE:
          InvokeDartCommand("togglePlayPause");
          return TRUE;
        case APPCOMMAND_MEDIA_PLAY:
          InvokeDartCommand("play");
          return TRUE;
        case APPCOMMAND_MEDIA_PAUSE:
          InvokeDartCommand("pause");
          return TRUE;
        case APPCOMMAND_MEDIA_PREVIOUSTRACK:
          InvokeDartCommand("previous");
          return TRUE;
        case APPCOMMAND_MEDIA_NEXTTRACK:
          InvokeDartCommand("next");
          return TRUE;
        case APPCOMMAND_MEDIA_STOP:
          InvokeDartCommand("stop");
          return TRUE;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::ConfigureNativeBackdrop() {
  const auto window = GetHandle();
  if (!window) {
    return;
  }
  const BOOL dark = TRUE;
  DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark,
                        sizeof(dark));
  DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &kDwmWindowCornerRound,
                        sizeof(kDwmWindowCornerRound));
  DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE,
                        &kDwmSystemBackdropMica,
                        sizeof(kDwmSystemBackdropMica));
}

void FlutterWindow::ConfigurePlatformChannel() {
  platform_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dev.intmusic/platform",
      &flutter::StandardMethodCodec::GetInstance());
  platform_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "initialize") {
          AddTrayIcon();
          flutter::EncodableMap capabilities;
          capabilities[flutter::EncodableValue("systemTray")] =
              flutter::EncodableValue(true);
          capabilities[flutter::EncodableValue("mediaSession")] =
              flutter::EncodableValue(media_session_ &&
                                      media_session_->available());
          capabilities[flutter::EncodableValue("nativeBackdrop")] =
              flutter::EncodableValue(true);
          capabilities[flutter::EncodableValue("backgroundPlayback")] =
              flutter::EncodableValue(true);
          result->Success(flutter::EncodableValue(capabilities));
          return;
        }
        if (call.method_name() == "updatePlayback") {
          if (media_session_) {
            if (const auto* payload =
                    std::get_if<flutter::EncodableMap>(call.arguments())) {
              media_session_->Update(*payload);
            }
          }
          result->Success();
          return;
        }
        if (call.method_name() == "showWindow") {
          ShowMainWindow();
          result->Success();
          return;
        }
        if (call.method_name() == "moveToBackground") {
          ShowWindow(GetHandle(), SW_HIDE);
          result->Success();
          return;
        }
        if (call.method_name() == "updateVolume") {
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_) {
    return;
  }
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_.hIcon = static_cast<HICON>(LoadImage(
      GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  wcscpy_s(tray_icon_.szTip, L"IntMusic");
  tray_icon_added_ = Shell_NotifyIcon(NIM_ADD, &tray_icon_) == TRUE;
  if (tray_icon_added_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIcon(NIM_SETVERSION, &tray_icon_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  Shell_NotifyIcon(NIM_DELETE, &tray_icon_);
  tray_icon_added_ = false;
  if (tray_icon_.hIcon) {
    DestroyIcon(tray_icon_.hIcon);
    tray_icon_.hIcon = nullptr;
  }
}

void FlutterWindow::ShowTrayMenu() {
  POINT cursor{};
  GetCursorPos(&cursor);
  HMENU menu = CreatePopupMenu();
  AppendMenu(menu, MF_STRING, kTrayShow, L"Show IntMusic");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kTrayPlayPause, L"Play / Pause");
  AppendMenu(menu, MF_STRING, kTrayPrevious, L"Previous");
  AppendMenu(menu, MF_STRING, kTrayNext, L"Next");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kTrayQuit, L"Quit IntMusic");
  SetForegroundWindow(GetHandle());
  TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, cursor.x, cursor.y,
                 0, GetHandle(), nullptr);
  DestroyMenu(menu);
}

void FlutterWindow::ShowMainWindow() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::InvokeDartCommand(const char* command) {
  if (!platform_channel_) {
    return;
  }
  platform_channel_->InvokeMethod(
      command,
      std::make_unique<flutter::EncodableValue>());
}
