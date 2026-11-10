// Small bundled worker using the Windows OCR runtime. No installer, PATH
// lookup, PowerShell script, network call, or user document files are needed.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <fcntl.h>
#include <io.h>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    if (argc != 3) return 2;
    const int width = std::stoi(argv[1]);
    const int height = std::stoi(argv[2]);
    using winrt::Windows::Media::Ocr::OcrEngine;
    if (width <= 0 || height <= 0 ||
        width > static_cast<int>(OcrEngine::MaxImageDimension()) ||
        height > static_cast<int>(OcrEngine::MaxImageDimension())) return 2;
    const size_t length = static_cast<size_t>(width) * height * 4;
    std::vector<uint8_t> pixels(length);
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    if (fread(pixels.data(), 1, length, stdin) != length) return 2;

    auto engine = OcrEngine::TryCreateFromLanguage(
        winrt::Windows::Globalization::Language(L"ko"));
    if (!engine) engine = OcrEngine::TryCreateFromUserProfileLanguages();
    if (!engine) engine = OcrEngine::TryCreateFromLanguage(
        winrt::Windows::Globalization::Language(L"en-US"));
    if (!engine) {
      fputs("Windows OCR language is unavailable.", stderr);
      return 3;
    }
    using namespace winrt::Windows::Graphics::Imaging;
    auto buffer = winrt::Windows::Security::Cryptography::CryptographicBuffer::CreateFromByteArray(pixels);
    auto bitmap = SoftwareBitmap::CreateCopyFromBuffer(
        buffer, BitmapPixelFormat::Bgra8, width, height, BitmapAlphaMode::Ignore);
    auto result = engine.RecognizeAsync(bitmap).get();
    const auto text = winrt::to_string(result.Text());
    fwrite(text.data(), 1, text.size(), stdout);
    bitmap.Close();
    return 0;
  } catch (const winrt::hresult_error& error) {
    const auto message = winrt::to_string(error.message());
    fputs(message.c_str(), stderr);
    return 4;
  } catch (const std::exception& error) {
    fputs(error.what(), stderr);
    return 4;
  }
}
