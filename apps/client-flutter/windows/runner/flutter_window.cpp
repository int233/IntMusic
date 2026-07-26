#include "flutter_window.h"

#include <dwmapi.h>
#include <endpointvolume.h>
#include <flutter/standard_method_codec.h>
#include <propkeydef.h>
#include <functiondiscoverykeys_devpkey.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <wrl/client.h>
#include <cwctype>
#include <cwchar>
#include <algorithm>
#include <iterator>
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
constexpr UINT kTrayHide = 41006;
constexpr UINT kTrayCoreStart = 41007;
constexpr UINT kTrayCoreRestart = 41008;
constexpr UINT kTrayCoreStop = 41009;

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

std::optional<double> DoubleArgument(const flutter::EncodableMap& map,
                                     const char* name) {
  auto value = map.find(flutter::EncodableValue(name));
  if (value == map.end()) {
    return std::nullopt;
  }
  if (const auto* number = std::get_if<double>(&value->second)) {
    return *number;
  }
  if (const auto* number = std::get_if<int32_t>(&value->second)) {
    return static_cast<double>(*number);
  }
  if (const auto* number = std::get_if<int64_t>(&value->second)) {
    return static_cast<double>(*number);
  }
  return std::nullopt;
}

bool BoolArgument(const flutter::EncodableMap& map, const char* name,
                  bool fallback = false) {
  auto value = map.find(flutter::EncodableValue(name));
  if (value == map.end()) {
    return fallback;
  }
  if (const auto* boolean = std::get_if<bool>(&value->second)) {
    return *boolean;
  }
  return fallback;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) { return std::towlower(character); });
  return value;
}

flutter::EncodableValue UnsupportedSystemVolume() {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("supported"), flutter::EncodableValue(false)},
      {flutter::EncodableValue("readable"), flutter::EncodableValue(false)},
      {flutter::EncodableValue("writable"), flutter::EncodableValue(false)},
      {flutter::EncodableValue("volume"), flutter::EncodableValue(1.0)},
      {flutter::EncodableValue("muted"), flutter::EncodableValue(false)},
  });
}

Microsoft::WRL::ComPtr<IMMDevice> ResolveAudioEndpoint(
    const flutter::EncodableMap& arguments) {
  using Microsoft::WRL::ComPtr;
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
    return nullptr;
  }
  if (BoolArgument(arguments, "isDefault", true)) {
    ComPtr<IMMDevice> endpoint;
    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(
            eRender, eMultimedia, &endpoint))) {
      return endpoint;
    }
    return nullptr;
  }

  std::wstring selector;
  if (const auto* raw = StringArgument(arguments, "outputName")) {
    selector = Lower(Utf8ToWide(*raw));
    constexpr wchar_t prefix[] = L"wasapi/";
    if (selector.rfind(prefix, 0) == 0) {
      selector.erase(0, std::size(prefix) - 1);
    }
  }
  std::wstring description;
  if (const auto* raw = StringArgument(arguments, "outputDescription")) {
    description = Lower(Utf8ToWide(*raw));
  }
  if (selector.empty() && description.empty()) {
    return nullptr;
  }

  ComPtr<IMMDeviceCollection> endpoints;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE,
                                             &endpoints))) {
    return nullptr;
  }
  UINT count = 0;
  endpoints->GetCount(&count);
  for (UINT index = 0; index < count; ++index) {
    ComPtr<IMMDevice> endpoint;
    if (FAILED(endpoints->Item(index, &endpoint))) {
      continue;
    }
    LPWSTR raw_id = nullptr;
    std::wstring endpoint_id;
    if (SUCCEEDED(endpoint->GetId(&raw_id)) && raw_id != nullptr) {
      endpoint_id = Lower(raw_id);
      CoTaskMemFree(raw_id);
    }
    std::wstring friendly_name;
    ComPtr<IPropertyStore> properties;
    if (SUCCEEDED(endpoint->OpenPropertyStore(STGM_READ, &properties))) {
      PROPVARIANT value;
      PropVariantInit(&value);
      if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &value)) &&
          value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
        friendly_name = Lower(value.pwszVal);
      }
      PropVariantClear(&value);
    }
    if ((!selector.empty() &&
         (endpoint_id == selector ||
          endpoint_id.find(selector) != std::wstring::npos)) ||
        (!description.empty() && friendly_name == description)) {
      return endpoint;
    }
  }
  return nullptr;
}

flutter::EncodableValue SystemVolumeState(
    const flutter::EncodableMap& arguments, bool apply) {
  const HRESULT initialized =
      CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool should_uninitialize = SUCCEEDED(initialized);
  auto endpoint = ResolveAudioEndpoint(arguments);
  Microsoft::WRL::ComPtr<IAudioEndpointVolume> volume_control;
  if (!endpoint ||
      FAILED(endpoint->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL,
                                nullptr, &volume_control))) {
    if (should_uninitialize) {
      CoUninitialize();
    }
    return UnsupportedSystemVolume();
  }
  bool writable = true;
  if (apply) {
    const auto requested = DoubleArgument(arguments, "volume").value_or(1.0);
    const float scalar =
        static_cast<float>(std::clamp(requested, 0.0, 1.0));
    writable =
        SUCCEEDED(volume_control->SetMasterVolumeLevelScalar(scalar, nullptr)) &&
        SUCCEEDED(
            volume_control->SetMute(BoolArgument(arguments, "muted"), nullptr));
  }
  float scalar = 1.0f;
  BOOL muted = FALSE;
  UINT step = 0;
  UINT step_count = 0;
  const bool readable =
      SUCCEEDED(volume_control->GetMasterVolumeLevelScalar(&scalar)) &&
      SUCCEEDED(volume_control->GetMute(&muted));
  volume_control->GetVolumeStepInfo(&step, &step_count);
  flutter::EncodableMap state{
      {flutter::EncodableValue("supported"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("readable"), flutter::EncodableValue(readable)},
      {flutter::EncodableValue("writable"), flutter::EncodableValue(writable)},
      {flutter::EncodableValue("volume"),
       flutter::EncodableValue(static_cast<double>(scalar))},
      {flutter::EncodableValue("muted"),
       flutter::EncodableValue(muted != FALSE)},
  };
  if (step_count > 0) {
    state[flutter::EncodableValue("steps")] =
        flutter::EncodableValue(static_cast<int64_t>(step_count));
  }
  if (should_uninitialize) {
    CoUninitialize();
  }
  return flutter::EncodableValue(std::move(state));
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

  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  installer_shutdown_message_ =
      RegisterWindowMessageW(L"IntMusic.ShutdownForUpdate");

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
  if (installer_shutdown_message_ != 0 &&
      message == installer_shutdown_message_) {
    RemoveTrayIcon();
    DestroyWindow(hwnd);
    PostQuitMessage(0);
    return 0;
  }
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    if (tray_icon_added_) {
      tray_icon_added_ = false;
      if (tray_icon_.hIcon) {
        DestroyIcon(tray_icon_.hIcon);
        tray_icon_.hIcon = nullptr;
      }
      AddTrayIcon();
    }
    return 0;
  }

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
    case kTrayCallbackMessage: {
      // NOTIFYICON_VERSION_4 stores the event code in LOWORD(lParam) and the
      // icon identifier in HIWORD(lParam). Comparing the complete lParam makes
      // every mouse event miss as soon as version 4 is enabled.
      const UINT notification =
          LOWORD(static_cast<DWORD_PTR>(lparam));
      if (notification == WM_LBUTTONDBLCLK) {
        ShowMainWindow();
      } else if (notification == WM_RBUTTONUP ||
                 notification == WM_CONTEXTMENU) {
        ShowTrayMenu();
      }
      return 0;
    }
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kTrayShow:
          ShowMainWindow();
          return 0;
        case kTrayHide:
          HideMainWindow();
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
        case kTrayCoreStart:
          RunCoreServiceAction(L"start");
          return 0;
        case kTrayCoreRestart:
          RunCoreServiceAction(L"restart");
          return 0;
        case kTrayCoreStop:
          RunCoreServiceAction(L"stop");
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
        if (call.method_name() == "getSystemVolume" ||
            call.method_name() == "setSystemVolume") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Success(UnsupportedSystemVolume());
            return;
          }
          result->Success(SystemVolumeState(
              *arguments, call.method_name() == "setSystemVolume"));
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
  if (!menu) {
    return;
  }
  const bool window_visible = IsWindowVisible(GetHandle()) == TRUE;
  AppendMenu(menu, MF_STRING, window_visible ? kTrayHide : kTrayShow,
             window_visible ? L"Hide IntMusic" : L"Show IntMusic");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kTrayPlayPause, L"Play / Pause");
  AppendMenu(menu, MF_STRING, kTrayPrevious, L"Previous");
  AppendMenu(menu, MF_STRING, kTrayNext, L"Next");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);

  const CoreServiceState core_state = QueryCoreServiceState();
  const wchar_t* core_status = L"Core: Unknown";
  switch (core_state) {
    case CoreServiceState::kNotInstalled:
      core_status = L"Core: Not installed";
      break;
    case CoreServiceState::kStopped:
      core_status = L"Core: Stopped";
      break;
    case CoreServiceState::kRunning:
      core_status = L"Core: Running";
      break;
    case CoreServiceState::kPaused:
      core_status = L"Core: Paused";
      break;
    case CoreServiceState::kPending:
      core_status = L"Core: Changing state...";
      break;
    case CoreServiceState::kUnknown:
      break;
  }
  AppendMenu(menu, MF_STRING | MF_GRAYED, 0, core_status);
  const bool can_start = core_state == CoreServiceState::kStopped;
  const bool can_restart = core_state == CoreServiceState::kRunning ||
                           core_state == CoreServiceState::kPaused;
  const bool can_stop = can_restart;
  AppendMenu(menu, MF_STRING | (can_start ? MF_ENABLED : MF_GRAYED),
             kTrayCoreStart, L"Start Core");
  AppendMenu(menu, MF_STRING | (can_restart ? MF_ENABLED : MF_GRAYED),
             kTrayCoreRestart, L"Restart Core");
  AppendMenu(menu, MF_STRING | (can_stop ? MF_ENABLED : MF_GRAYED),
             kTrayCoreStop, L"Stop Core");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kTrayQuit, L"Quit IntMusic");
  SetMenuDefaultItem(menu, window_visible ? kTrayHide : kTrayShow, FALSE);
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(
      menu,
      TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN | TPM_RETURNCMD |
          TPM_NONOTIFY,
      cursor.x, cursor.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  if (command != 0) {
    PostMessageW(GetHandle(), WM_COMMAND, MAKEWPARAM(command, 0), 0);
  }
  // Required by the shell so clicking outside reliably dismisses the menu.
  PostMessageW(GetHandle(), WM_NULL, 0, 0);
}

void FlutterWindow::ShowMainWindow() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::HideMainWindow() {
  ShowWindow(GetHandle(), SW_HIDE);
}

FlutterWindow::CoreServiceState FlutterWindow::QueryCoreServiceState() const {
  SC_HANDLE manager =
      OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) {
    return CoreServiceState::kUnknown;
  }
  SC_HANDLE service =
      OpenServiceW(manager, L"IntMusicCore", SERVICE_QUERY_STATUS);
  if (!service) {
    const DWORD error = GetLastError();
    CloseServiceHandle(manager);
    return error == ERROR_SERVICE_DOES_NOT_EXIST
               ? CoreServiceState::kNotInstalled
               : CoreServiceState::kUnknown;
  }

  SERVICE_STATUS_PROCESS status{};
  DWORD bytes_needed = 0;
  const BOOL queried = QueryServiceStatusEx(
      service, SC_STATUS_PROCESS_INFO,
      reinterpret_cast<LPBYTE>(&status), sizeof(status), &bytes_needed);
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  if (!queried) {
    return CoreServiceState::kUnknown;
  }
  switch (status.dwCurrentState) {
    case SERVICE_STOPPED:
      return CoreServiceState::kStopped;
    case SERVICE_RUNNING:
      return CoreServiceState::kRunning;
    case SERVICE_PAUSED:
      return CoreServiceState::kPaused;
    case SERVICE_START_PENDING:
    case SERVICE_STOP_PENDING:
    case SERVICE_CONTINUE_PENDING:
    case SERVICE_PAUSE_PENDING:
      return CoreServiceState::kPending;
    default:
      return CoreServiceState::kUnknown;
  }
}

void FlutterWindow::RunCoreServiceAction(const wchar_t* action) {
  std::wstring script;
  if (wcscmp(action, L"start") == 0) {
    script =
        L"Start-Service -Name 'IntMusicCore' -ErrorAction Stop";
  } else if (wcscmp(action, L"restart") == 0) {
    script =
        L"Restart-Service -Name 'IntMusicCore' -Force -ErrorAction Stop";
  } else if (wcscmp(action, L"stop") == 0) {
    script =
        L"Stop-Service -Name 'IntMusicCore' -Force -ErrorAction Stop";
  } else {
    return;
  }

  const std::wstring parameters =
      L"-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "
      L"\"& { " +
      script + L" }\"";
  const HINSTANCE launched =
      ShellExecuteW(GetHandle(), L"runas", L"powershell.exe",
                    parameters.c_str(), nullptr, SW_HIDE);
  if (reinterpret_cast<INT_PTR>(launched) <= 32) {
    MessageBoxW(
        GetHandle(),
        L"Windows could not run the Core service command. Approve the "
        L"administrator prompt and try again.",
        L"IntMusic Core", MB_OK | MB_ICONERROR);
  }
}

void FlutterWindow::InvokeDartCommand(const char* command) {
  if (!platform_channel_) {
    return;
  }
  platform_channel_->InvokeMethod(
      command,
      std::make_unique<flutter::EncodableValue>());
}
