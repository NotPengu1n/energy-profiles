#ifndef RUNNER_ENERGY_BACKEND_H_
#define RUNNER_ENERGY_BACKEND_H_
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include "system_controls.h"

class EnergyBackend {
 public:
  explicit EnergyBackend(flutter::BinaryMessenger* messenger);
  ~EnergyBackend();
  static int Diagnostics();
 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  using Result = flutter::MethodResult<Value>;
  void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result);
  Value Snapshot();
  Value Apply(const Map& args);
  Value Status();
  Value Confirm(int id);
  Value Cancel(int id);
  bool Restore();
  void Watchdog();
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::thread watchdog_;
  bool stopping_ = false;
  int transaction_id_ = 0;
  std::string state_ = "idle", message_;
  std::wstring device_;
  DEVMODEW original_{}, proposed_{};
  GUID original_power_{}, normal_power_{}, previous_normal_power_{};
  GUID original_ac_{}, original_dc_{}, normal_ac_{}, normal_dc_{};
  GUID previous_normal_ac_{}, previous_normal_dc_{};
  bool modern_power_ = false, modes_changed_ = false;
  bool display_changed_ = false, power_changed_ = false;
  std::chrono::steady_clock::time_point deadline_;
  struct Thresholds { DWORD ac; DWORD dc; };
  std::map<std::string,Thresholds> normal_thresholds_, previous_thresholds_;
  GUID threshold_scheme_{};
  Thresholds original_thresholds_{};
  bool thresholds_changed_ = false, requested_saver_ = false;
  EnergySaverStatus energy_status_;
  std::wstring brightness_instance_;
  int original_brightness_ = 0;
  bool brightness_changed_ = false;
};
#endif
