#include "screen_capture_channel.h"

#include <windows.h>
#include <windowsx.h>  // GET_X_LPARAM / GET_Y_LPARAM
#include <wincodec.h>  // WIC: encode the captured bitmap straight to PNG
#include <wrl/client.h>

#include <algorithm>
#include <memory>
#include <vector>

using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

constexpr char kChannelName[] = "screen_translate/capture";
constexpr wchar_t kSelectorClassName[] = L"ScreenTranslateRegionSelector";

// Captures the given device-pixel rect of the virtual screen via classic
// GDI BitBlt and returns it as PNG-encoded bytes using WIC (Windows
// Imaging Component) — no extra native dependency, ships with Windows.
//
// NOTE: BitBlt captures desktop composition (DWM) output, so protected
// content (DRM video, some secure-mode windows) will appear black. For
// window/tab-accurate capture equivalent to Windows.Graphics.Capture,
// swap this for the WinRT GraphicsCaptureSession API — the method
// channel surface here stays the same either way.
std::vector<uint8_t> CaptureRectAsPng(int x, int y, int width, int height) {
  HDC screen_dc = GetDC(nullptr);
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  HBITMAP bitmap = CreateCompatibleBitmap(screen_dc, width, height);
  HGDIOBJ old_obj = SelectObject(mem_dc, bitmap);

  BitBlt(mem_dc, 0, 0, width, height, screen_dc, x, y, SRCCOPY | CAPTUREBLT);

  // --- Encode HBITMAP -> PNG bytes via WIC ---
  std::vector<uint8_t> png_bytes;
  ComPtr<IWICImagingFactory> wic_factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                 IID_PPV_ARGS(&wic_factory));
  if (SUCCEEDED(hr)) {
    ComPtr<IWICBitmap> wic_bitmap;
    hr = wic_factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapUseAlpha, &wic_bitmap);

    ComPtr<IStream> stream;
    if (SUCCEEDED(hr)) hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);

    ComPtr<IWICBitmapEncoder> encoder;
    if (SUCCEEDED(hr)) {
      hr = wic_factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    }
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);

    ComPtr<IWICBitmapFrameEncode> frame;
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, nullptr);
    if (SUCCEEDED(hr)) hr = frame->Initialize(nullptr);
    if (SUCCEEDED(hr)) hr = frame->SetSize(width, height);

    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
    if (SUCCEEDED(hr)) hr = frame->WriteSource(wic_bitmap.Get(), nullptr);
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();

    if (SUCCEEDED(hr)) {
      STATSTG stats;
      stream->Stat(&stats, STATFLAG_NONAME);
      png_bytes.resize(stats.cbSize.LowPart);
      LARGE_INTEGER zero = {};
      stream->Seek(zero, STREAM_SEEK_SET, nullptr);
      ULONG bytes_read = 0;
      stream->Read(png_bytes.data(), static_cast<ULONG>(png_bytes.size()), &bytes_read);
    }
  }

  SelectObject(mem_dc, old_obj);
  DeleteObject(bitmap);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  return png_bytes;
}

// Normalizes to left<=right / top<=bottom (the user can drag in any
// direction) and clamps to the virtual screen bounds passed to the
// selector window, so a drag that overshoots past a monitor edge doesn't
// produce an out-of-bounds crop.
RECT NormalizeAndClamp(POINT a, POINT b, const RECT& bounds) {
  RECT r{std::min(a.x, b.x), std::min(a.y, b.y), std::max(a.x, b.x), std::max(a.y, b.y)};
  r.left = std::clamp(r.left, bounds.left, bounds.right);
  r.right = std::clamp(r.right, bounds.left, bounds.right);
  r.top = std::clamp(r.top, bounds.top, bounds.bottom);
  r.bottom = std::clamp(r.bottom, bounds.top, bounds.bottom);
  return r;
}

// Full-screen click-drag region picker: a topmost, per-pixel-alpha layered
// window that dims the whole (possibly multi-monitor) virtual screen and
// "punches a hole" showing the real desktop wherever the user is
// dragging, the same visual language as the Windows Snipping Tool /
// ShareX region picker. Esc cancels.
//
// Runs its own nested GetMessage loop on the calling (UI) thread rather
// than posting WM_QUIT — PostQuitMessage would enqueue a thread-wide quit
// that Flutter's own main loop would pick up next and exit the whole app,
// since this handler executes on the same thread as the main window.
class RegionSelector {
 public:
  // Returns an empty-width/height RECT if the user pressed Esc.
  static RECT Run() {
    RegionSelector selector;
    return selector.RunInternal();
  }

 private:
  RECT virtual_screen_{};
  POINT start_{};
  POINT current_{};
  bool dragging_ = false;
  bool done_ = false;
  bool cancelled_ = false;
  HWND hwnd_ = nullptr;

  RECT RunInternal() {
    virtual_screen_ = RECT{
        GetSystemMetrics(SM_XVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN),
        GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN) + GetSystemMetrics(SM_CYVIRTUALSCREEN),
    };

    EnsureClassRegistered();

    hwnd_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kSelectorClassName, L"",
        WS_POPUP, virtual_screen_.left, virtual_screen_.top,
        virtual_screen_.right - virtual_screen_.left,
        virtual_screen_.bottom - virtual_screen_.top, nullptr, nullptr,
        GetModuleHandle(nullptr), this);
    if (!hwnd_) return RECT{0, 0, 0, 0};

    Render();  // initial full-screen dim, before any drag
    ShowWindow(hwnd_, SW_SHOW);
    SetForegroundWindow(hwnd_);

    MSG msg;
    while (!done_) {
      BOOL got = GetMessage(&msg, nullptr, 0, 0);
      if (got <= 0) break;  // WM_QUIT or error from elsewhere; give up cleanly
      TranslateMessage(&msg);
      DispatchMessage(&msg);
    }

    if (IsWindow(hwnd_)) DestroyWindow(hwnd_);

    if (cancelled_) return RECT{0, 0, 0, 0};
    RECT selection = NormalizeAndClamp(start_, current_, virtual_screen_);
    // Treat an accidental single-pixel click (no real drag) as a cancel.
    if (selection.right - selection.left < 4 || selection.bottom - selection.top < 4) {
      return RECT{0, 0, 0, 0};
    }
    return selection;
  }

  static void EnsureClassRegistered() {
    static bool registered = false;
    if (registered) return;
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = &RegionSelector::WndProc;
    wc.hInstance = GetModuleHandle(nullptr);
    wc.hCursor = LoadCursor(nullptr, IDC_CROSS);
    wc.lpszClassName = kSelectorClassName;
    RegisterClassExW(&wc);
    registered = true;
  }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    RegionSelector* self;
    if (msg == WM_NCCREATE) {
      auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
      self = reinterpret_cast<RegionSelector*>(create->lpCreateParams);
      SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
      self = reinterpret_cast<RegionSelector*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    }
    if (self) return self->HandleMessage(hwnd, msg, wparam, lparam);
    return DefWindowProc(hwnd, msg, wparam, lparam);
  }

  LRESULT HandleMessage(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
      case WM_LBUTTONDOWN:
        start_ = current_ = ScreenPointFromLParam(lparam);
        dragging_ = true;
        SetCapture(hwnd);
        return 0;

      case WM_MOUSEMOVE:
        if (dragging_) {
          current_ = ScreenPointFromLParam(lparam);
          Render();
        }
        return 0;

      case WM_LBUTTONUP:
        if (dragging_) {
          current_ = ScreenPointFromLParam(lparam);
          dragging_ = false;
          ReleaseCapture();
          done_ = true;
        }
        return 0;

      case WM_KEYDOWN:
        if (wparam == VK_ESCAPE) {
          cancelled_ = true;
          done_ = true;
        }
        return 0;

      case WM_CAPTURECHANGED:
        // Mouse capture was stolen out from under us (e.g. Alt+Tab, a UAC
        // prompt) mid-drag — we'll never get the matching WM_LBUTTONUP,
        // so treat it as a cancel instead of hanging the selector open.
        if (dragging_) {
          dragging_ = false;
          cancelled_ = true;
          done_ = true;
        }
        return 0;

      case WM_DESTROY:
        return 0;  // deliberately no PostQuitMessage — see class comment

      default:
        return DefWindowProc(hwnd, msg, wparam, lparam);
    }
  }

  // Mouse coordinates in WM_MOUSEMOVE/WM_LBUTTONDOWN are client-relative;
  // offset by the window's virtual-screen origin to get absolute
  // desktop coordinates (needed since the window spans possibly-negative
  // multi-monitor coordinates).
  POINT ScreenPointFromLParam(LPARAM lparam) const {
    return POINT{
        virtual_screen_.left + GET_X_LPARAM(lparam),
        virtual_screen_.top + GET_Y_LPARAM(lparam),
    };
  }

  // Repaints the layered window's per-pixel-alpha buffer: dim everywhere
  // except a fully-transparent "hole" over the current drag rectangle,
  // with a solid border traced around it for visibility. Redraws the
  // whole buffer each call for simplicity — see NOTES.md if you need to
  // optimize this to a dirty-rect update for very large / high-refresh
  // multi-monitor setups.
  void Render() {
    const int width = virtual_screen_.right - virtual_screen_.left;
    const int height = virtual_screen_.bottom - virtual_screen_.top;
    if (width <= 0 || height <= 0) return;

    RECT sel = NormalizeAndClamp(start_, current_, virtual_screen_);
    // Selection rect in buffer-local (window-client) coordinates.
    const int sel_left = sel.left - virtual_screen_.left;
    const int sel_top = sel.top - virtual_screen_.top;
    const int sel_right = sel.right - virtual_screen_.left;
    const int sel_bottom = sel.bottom - virtual_screen_.top;

    HDC screen_dc = GetDC(nullptr);
    HDC mem_dc = CreateCompatibleDC(screen_dc);

    BITMAPINFO bmi{};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = width;
    bmi.bmiHeader.biHeight = -height;  // negative = top-down DIB
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    HBITMAP dib = CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HGDIOBJ old_bmp = SelectObject(mem_dc, dib);

    if (bits) {
      auto* pixels = static_cast<uint32_t*>(bits);
      // Premultiplied BGRA, as UpdateLayeredWindow with ULW_ALPHA requires.
      constexpr uint32_t kDim = 0x50000000;       // ~31% black overlay
      constexpr uint32_t kClear = 0x00000000;     // fully see-through
      constexpr uint32_t kBorder = 0xFF29B6F6;    // opaque accent-blue border

      for (int row = 0; row < height; ++row) {
        uint32_t* row_px = pixels + static_cast<size_t>(row) * width;
        const bool in_sel_rows = row >= sel_top && row < sel_bottom;
        if (!in_sel_rows) {
          std::fill_n(row_px, width, kDim);
          continue;
        }
        const bool on_border_row = row == sel_top || row == sel_bottom - 1;
        std::fill_n(row_px, sel_left, kDim);
        const int inner_width = sel_right - sel_left;
        if (on_border_row || inner_width <= 2) {
          std::fill_n(row_px + sel_left, inner_width, kBorder);
        } else {
          row_px[sel_left] = kBorder;
          std::fill_n(row_px + sel_left + 1, inner_width - 2, kClear);
          row_px[sel_right - 1] = kBorder;
        }
        std::fill_n(row_px + sel_right, width - sel_right, kDim);
      }
    }

    POINT pt_src{0, 0};
    POINT pt_dst{virtual_screen_.left, virtual_screen_.top};
    SIZE size_wnd{width, height};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(hwnd_, screen_dc, &pt_dst, &size_wnd, mem_dc, &pt_src, 0, &blend,
                         ULW_ALPHA);

    SelectObject(mem_dc, old_bmp);
    DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
  }
};

}  // namespace

void ScreenCaptureChannel::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_shared<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), kChannelName, &flutter::StandardMethodCodec::GetInstance());

  auto* plugin = new ScreenCaptureChannel();
  channel->SetMethodCallHandler(
      [plugin](const auto& call, auto result) { plugin->HandleMethodCall(call, std::move(result)); });
}

ScreenCaptureChannel::ScreenCaptureChannel() { CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); }
ScreenCaptureChannel::~ScreenCaptureChannel() { CoUninitialize(); }

void ScreenCaptureChannel::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() == "captureFullScreen") {
    result->Success(EncodableValue(CaptureFullScreen()));
  } else if (call.method_name() == "captureRegion") {
    auto region = CaptureRegion();
    if (region.empty()) {
      result->Error("CAPTURE_CANCELLED", "User cancelled region selection");
    } else {
      result->Success(EncodableValue(region));
    }
  } else {
    result->NotImplemented();
  }
}

EncodableMap ScreenCaptureChannel::CaptureFullScreen() {
  const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  const int height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  const int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int y = GetSystemMetrics(SM_YVIRTUALSCREEN);

  auto png = CaptureRectAsPng(x, y, width, height);
  return EncodableMap{
      {EncodableValue("pngBytes"), EncodableValue(png)},
      {EncodableValue("pixelWidth"), EncodableValue(width)},
      {EncodableValue("pixelHeight"), EncodableValue(height)},
  };
}

EncodableMap ScreenCaptureChannel::CaptureRegion() {
  const RECT virtual_screen{
      GetSystemMetrics(SM_XVIRTUALSCREEN),
      GetSystemMetrics(SM_YVIRTUALSCREEN),
      GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN),
      GetSystemMetrics(SM_YVIRTUALSCREEN) + GetSystemMetrics(SM_CYVIRTUALSCREEN),
  };

  const RECT selection = RegionSelector::Run();
  const int width = selection.right - selection.left;
  const int height = selection.bottom - selection.top;
  if (width <= 0 || height <= 0) return EncodableMap{};  // user pressed Esc / cancelled

  auto png = CaptureRectAsPng(selection.left, selection.top, width, height);

  // GetDpiForSystem() reflects the PRIMARY monitor's scale factor only.
  // On a mixed-DPI multi-monitor setup where the user drags a region on a
  // secondary monitor with a different scale factor, logicalWidth/Height
  // (and therefore CaptureFrame.scaleX/Y on the Dart side) will be
  // slightly off for that monitor. Swap in GetDpiForMonitor(MonitorFrom
  // Rect(&selection, ...)) from <shellscalingapi.h> (link shcore.lib) for
  // exact per-monitor accuracy if you need to support that setup.
  const UINT dpi = GetDpiForSystem();
  const double scale = dpi / 96.0;

  return EncodableMap{
      {EncodableValue("pngBytes"), EncodableValue(png)},
      {EncodableValue("pixelWidth"), EncodableValue(width)},
      {EncodableValue("pixelHeight"), EncodableValue(height)},
      {EncodableValue("logicalWidth"), EncodableValue(width / scale)},
      {EncodableValue("logicalHeight"), EncodableValue(height / scale)},
      // Offset of the selection's top-left within the full virtual screen,
      // in the same physical-pixel space as CaptureFullScreen's frame —
      // this is what lets service_windows.dart position OCR boxes
      // (which are relative to this cropped image) correctly inside the
      // full-screen overlay window.
      {EncodableValue("originX"),
       EncodableValue(static_cast<double>(selection.left - virtual_screen.left))},
      {EncodableValue("originY"),
       EncodableValue(static_cast<double>(selection.top - virtual_screen.top))},
  };
}
