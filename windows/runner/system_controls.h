#ifndef RUNNER_SYSTEM_CONTROLS_H_
#define RUNNER_SYSTEM_CONTROLS_H_
#include <windows.h>
#include <atomic>
#include <optional>
#include <string>
#include <vector>

class EnergySaverStatus {
 public:
  EnergySaverStatus();
  ~EnergySaverStatus();
  int value() const;
 private:
  static ULONG CALLBACK Callback(PVOID context, ULONG type, PVOID setting);
  std::atomic<int> state_{-1};
  HPOWERNOTIFY notification_ = nullptr;
};
struct BrightnessInfo {
  std::wstring instance;
  int value;
  std::vector<int> levels;
};
std::optional<BrightnessInfo> ReadBrightness(const std::wstring& monitor_interface);
bool WriteBrightness(const std::wstring& instance, int value);
#endif
