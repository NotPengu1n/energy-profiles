#include "energy_backend.h"
#include <powrprof.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <set>
#include <stdexcept>
#include <tuple>
#include <vector>
#include <shellapi.h>

namespace {
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
using L = flutter::EncodableList;
constexpr GUID kSaver = {0xa1841308, 0x3541, 0x4fab, {0xbc,0x81,0xf7,0x15,0x56,0xf2,0x0b,0x4a}};
constexpr GUID kBalanced = {0x381b4222, 0xf694, 0x41f0, {0x96,0x85,0xff,0x5b,0xb2,0x60,0xdf,0x2e}};
constexpr GUID kEfficiency = {0x961cc777,0x2547,0x4f9d,{0x81,0x74,0x7d,0x86,0x18,0x1b,0x8a,0x7a}};
constexpr GUID kPerformance = {0xded574b5,0x45a0,0x4f42,{0x87,0x37,0x46,0x34,0x5c,0x09,0xc2,0x38}};
template <typename Function> Function PowerFunction(const char* name) {
  const auto address = GetProcAddress(GetModuleHandleW(L"powrprof.dll"),name);
  Function function = nullptr;
  static_assert(sizeof(function) == sizeof(address));
  std::memcpy(&function,&address,sizeof(function));
  return function;
}
struct PowerModeApi {
  using Get = DWORD (WINAPI*)(GUID*);
  using Set = DWORD (WINAPI*)(const GUID*);
  Get get_ac = PowerFunction<Get>("PowerGetUserConfiguredACPowerMode");
  Get get_dc = PowerFunction<Get>("PowerGetUserConfiguredDCPowerMode");
  Set set_ac = PowerFunction<Set>("PowerSetUserConfiguredACPowerMode");
  Set set_dc = PowerFunction<Set>("PowerSetUserConfiguredDCPowerMode");
  bool Read(GUID* ac, GUID* dc) const {
    return get_ac && get_dc && set_ac && set_dc && get_ac(ac) == ERROR_SUCCESS && get_dc(dc) == ERROR_SUCCESS;
  }
};
const PowerModeApi& ModernPower() { static const PowerModeApi api; return api; }
bool ValidPowerMode(const GUID& id) {
  return IsEqualGUID(id,GUID_NULL) || IsEqualGUID(id,kEfficiency) || IsEqualGUID(id,kPerformance);
}
std::string ModeName(const GUID& id) {
  if (IsEqualGUID(id,kEfficiency)) return "Максимальная энергоэффективность";
  if (IsEqualGUID(id,kPerformance)) return "Максимальная производительность";
  return "Сбалансированный режим";
}
std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), size, nullptr, nullptr);
  return result;
}
std::wstring Wide(const std::string& text) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size);
  return result;
}
std::string GuidText(const GUID& id) {
  wchar_t buffer[40]{};
  StringFromGUID2(id, buffer, 40);
  return Utf8(buffer);
}
GUID ActivePower() {
  GUID* id = nullptr;
  const DWORD code = PowerGetActiveScheme(nullptr, &id);
  if (code != ERROR_SUCCESS || !id) throw std::runtime_error("Не удалось прочитать план питания Windows (" + std::to_string(code) + ").");
  const GUID value = *id;
  LocalFree(id);
  return value;
}
std::vector<GUID> PowerPlans() {
  std::vector<GUID> plans;
  for (ULONG index = 0;; ++index) {
    GUID id{};
    DWORD size = sizeof(id);
    const auto code = PowerEnumerate(nullptr, nullptr, nullptr, ACCESS_SCHEME, index, reinterpret_cast<UCHAR*>(&id), &size);
    if (code == ERROR_NO_MORE_ITEMS) break;
    if (code != ERROR_SUCCESS) throw std::runtime_error("Не удалось получить список планов питания.");
    plans.push_back(id);
  }
  return plans;
}
bool HasPlan(const std::vector<GUID>& plans, const GUID& id) {
  return std::any_of(plans.begin(), plans.end(), [&](const GUID& item) { return IsEqualGUID(item, id); });
}
std::string PlanName(const GUID& id) {
  DWORD size = 0;
  PowerReadFriendlyName(nullptr, &id, nullptr, nullptr, nullptr, &size);
  if (!size) return GuidText(id);
  std::vector<wchar_t> name(size / sizeof(wchar_t) + 1, L'\0');
  if (PowerReadFriendlyName(nullptr, &id, nullptr, nullptr, reinterpret_cast<UCHAR*>(name.data()), &size) != ERROR_SUCCESS) return GuidText(id);
  return Utf8(name.data());
}
std::string ModeError(LONG error) {
  switch (error) {
    case DISP_CHANGE_BADMODE: return "Монитор не поддерживает выбранный режим.";
    case DISP_CHANGE_RESTART: return "Драйвер требует перезагрузку. Выберите другой режим.";
    case DISP_CHANGE_NOTUPDATED: return "Windows не удалось сохранить режим экрана.";
    default: return "Не удалось переключить режим экрана (" + std::to_string(error) + ").";
  }
}
V ModeValue(const DEVMODEW& mode) {
  return V(M{{V("width"),V(static_cast<int>(mode.dmPelsWidth))}, {V("height"),V(static_cast<int>(mode.dmPelsHeight))}, {V("hz"),V(static_cast<int>(mode.dmDisplayFrequency))}});
}
bool CurrentMode(const std::wstring& device, DEVMODEW* mode) {
  *mode = {};
  mode->dmSize = sizeof(DEVMODEW);
  return EnumDisplaySettingsExW(device.c_str(), ENUM_CURRENT_SETTINGS, mode, 0);
}
std::vector<DEVMODEW> Modes(const std::wstring& device, const DEVMODEW& current) {
  std::vector<DEVMODEW> modes;
  std::set<std::tuple<DWORD,DWORD,DWORD>> keys;
  for (DWORD index = 0;; ++index) {
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    if (!EnumDisplaySettingsExW(device.c_str(), index, &mode, 0)) break;
    if (mode.dmBitsPerPel != current.dmBitsPerPel || mode.dmDisplayOrientation != current.dmDisplayOrientation || (mode.dmDisplayFlags & DM_INTERLACED) || mode.dmDisplayFrequency <= 1 || !mode.dmPelsWidth || !mode.dmPelsHeight) continue;
    if (keys.insert({mode.dmPelsWidth, mode.dmPelsHeight, mode.dmDisplayFrequency}).second) modes.push_back(mode);
  }
  if (keys.insert({current.dmPelsWidth,current.dmPelsHeight,current.dmDisplayFrequency}).second) modes.push_back(current);
  return modes;
}
const V& Required(const M& args, const char* name) {
  auto item = args.find(V(name));
  if (item == args.end()) throw std::runtime_error("Отсутствует параметр профиля.");
  return item->second;
}
int Integer(const M& args, const char* name) {
  if (const auto* value = std::get_if<int32_t>(&Required(args,name))) return *value;
  throw std::runtime_error("Некорректный числовой параметр профиля.");
}
std::string Text(const M& args, const char* name) {
  if (const auto* value = std::get_if<std::string>(&Required(args,name))) return *value;
  throw std::runtime_error("Некорректное имя монитора.");
}
bool Boolean(const M& args, const char* name) {
  if (const auto* value = std::get_if<bool>(&Required(args,name))) return *value;
  throw std::runtime_error("Некорректная настройка энергосбережения.");
}
bool ReadThresholds(const GUID& scheme, DWORD* ac, DWORD* dc) {
  return PowerReadACValueIndex(nullptr,&scheme,&GUID_ENERGY_SAVER_SUBGROUP,&GUID_ENERGY_SAVER_BATTERY_THRESHOLD,ac) == ERROR_SUCCESS &&
      PowerReadDCValueIndex(nullptr,&scheme,&GUID_ENERGY_SAVER_SUBGROUP,&GUID_ENERGY_SAVER_BATTERY_THRESHOLD,dc) == ERROR_SUCCESS;
}
DWORD WriteThresholds(const GUID& scheme, DWORD ac, DWORD dc) {
  const auto first = PowerWriteACValueIndex(nullptr,&scheme,&GUID_ENERGY_SAVER_SUBGROUP,&GUID_ENERGY_SAVER_BATTERY_THRESHOLD,ac);
  if (first != ERROR_SUCCESS) return first;
  return PowerWriteDCValueIndex(nullptr,&scheme,&GUID_ENERGY_SAVER_SUBGROUP,&GUID_ENERGY_SAVER_BATTERY_THRESHOLD,dc);
}
std::optional<BrightnessInfo> MonitorBrightness(const std::wstring& device) {
  DISPLAY_DEVICEW monitor{}; monitor.cb = sizeof(monitor);
  if (!EnumDisplayDevicesW(device.c_str(),0,&monitor,EDD_GET_DEVICE_INTERFACE_NAME)) return std::nullopt;
  return ReadBrightness(monitor.DeviceID);
}
}  // namespace

EnergyBackend::EnergyBackend(flutter::BinaryMessenger* messenger) {
  try { const GUID active = ActivePower(); normal_power_ = IsEqualGUID(active,kSaver) ? kBalanced : active; }
  catch (...) { normal_power_ = kBalanced; }
  GUID ac{}, dc{};
  if (ModernPower().Read(&ac,&dc)) {
    normal_ac_ = IsEqualGUID(ac,kEfficiency) ? GUID_NULL : ac;
    normal_dc_ = IsEqualGUID(dc,kEfficiency) ? GUID_NULL : dc;
  }
  channel_ = std::make_unique<flutter::MethodChannel<V>>(messenger,"app.energy/profiles",&flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { Handle(call,std::move(result)); });
  watchdog_ = std::thread([this] { Watchdog(); });
}
EnergyBackend::~EnergyBackend() {
  channel_->SetMethodCallHandler(nullptr);
  { std::lock_guard<std::mutex> lock(mutex_); if (state_ == "pending") Restore(); stopping_ = true; }
  wake_.notify_all();
  if (watchdog_.joinable()) watchdog_.join();
}
void EnergyBackend::Handle(const flutter::MethodCall<V>& call, std::unique_ptr<Result> result) {
  try {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto* args = call.arguments() ? std::get_if<M>(call.arguments()) : nullptr;
    if (call.method_name() == "snapshot") result->Success(Snapshot());
    else if (call.method_name() == "status") result->Success(Status());
    else if (call.method_name() == "apply" && args) result->Success(Apply(*args));
    else if (call.method_name() == "confirm" && args) result->Success(Confirm(Integer(*args,"id")));
    else if (call.method_name() == "cancel" && args) result->Success(Cancel(Integer(*args,"id")));
    else if (call.method_name() == "openPowerSettings") {
      const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr,L"open",L"ms-settings:batterysaver-settings",nullptr,nullptr,SW_SHOWNORMAL));
      if (opened <= 32) throw std::runtime_error("Не удалось открыть настройки питания Windows.");
      result->Success();
    }
    else if (call.method_name() == "configure" && args) {
      GUID saved{};
      const auto text = Wide(Text(*args,"normalPowerScheme"));
      if (state_ != "pending" && SUCCEEDED(CLSIDFromString(text.c_str(),&saved)) && !IsEqualGUID(saved,kSaver) && HasPlan(PowerPlans(),saved) && IsEqualGUID(ActivePower(),kSaver)) normal_power_ = saved;
      GUID ac{}, dc{};
      const auto thresholds = args->find(V("normalEnergyThresholds"));
      if (state_ != "pending" && thresholds != args->end()) {
        if (const auto* saved_values = std::get_if<M>(&thresholds->second)) {
          for (const auto& entry : *saved_values) {
            const auto* key = std::get_if<std::string>(&entry.first);
            const auto* item = std::get_if<M>(&entry.second);
            GUID scheme{};
            if (!key || !item || FAILED(CLSIDFromString(Wide(*key).c_str(),&scheme)) || !HasPlan(PowerPlans(),scheme)) continue;
            const int saved_ac = Integer(*item,"ac"), saved_dc = Integer(*item,"dc");
            if (saved_ac >= 0 && saved_ac <= 100 && saved_dc >= 0 && saved_dc <= 100) normal_thresholds_[GuidText(scheme)] = {static_cast<DWORD>(saved_ac),static_cast<DWORD>(saved_dc)};
          }
        }
      }
      if (state_ != "pending" && ModernPower().Read(&ac,&dc)) {
        for (const char* key : {"normalAcMode","normalDcMode"}) {
          const auto item = args->find(V(key));
          if (item == args->end()) continue;
          const auto* value = std::get_if<std::string>(&item->second);
          GUID mode{};
          if (!value || FAILED(CLSIDFromString(Wide(*value).c_str(),&mode)) || !ValidPowerMode(mode) || IsEqualGUID(mode,kEfficiency)) continue;
          if (std::string(key) == "normalAcMode" && IsEqualGUID(ac,kEfficiency)) normal_ac_ = mode;
          if (std::string(key) == "normalDcMode" && IsEqualGUID(dc,kEfficiency)) normal_dc_ = mode;
        }
      }
      result->Success();
    } else result->NotImplemented();
  } catch (const std::exception& error) { result->Error("WINDOWS_ERROR",error.what()); }
}
EnergyBackend::Value EnergyBackend::Snapshot() {
  L monitors;
  for (DWORD index = 0;; ++index) {
    DISPLAY_DEVICEW adapter{}; adapter.cb = sizeof(adapter);
    if (!EnumDisplayDevicesW(nullptr,index,&adapter,0)) break;
    if (!(adapter.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) || (adapter.StateFlags & DISPLAY_DEVICE_MIRRORING_DRIVER)) continue;
    DEVMODEW current{};
    if (!CurrentMode(adapter.DeviceName,&current)) continue;
    DISPLAY_DEVICEW monitor{}; monitor.cb = sizeof(monitor);
    EnumDisplayDevicesW(adapter.DeviceName,0,&monitor,EDD_GET_DEVICE_INTERFACE_NAME);
    const auto brightness = ReadBrightness(monitor.DeviceID);
    L levels;
    if (brightness) for (int value : brightness->levels) levels.emplace_back(value);
    L modes;
    for (const auto& mode : Modes(adapter.DeviceName,current)) modes.push_back(ModeValue(mode));
    const std::wstring name = monitor.DeviceString[0] ? monitor.DeviceString : adapter.DeviceString;
    monitors.emplace_back(M{{V("id"),V(Utf8(adapter.DeviceName))}, {V("name"),V(Utf8(name))}, {V("primary"),V(bool(adapter.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE))}, {V("current"),ModeValue(current)}, {V("modes"),V(modes)}, {V("brightness"),brightness ? V(brightness->value) : V()}, {V("brightnessLevels"),V(levels)}});
  }
  const GUID active = ActivePower();
  const bool classic = HasPlan(PowerPlans(),kSaver);
  GUID ac{}, dc{};
  const bool modern = !classic && ModernPower().Read(&ac,&dc);
  SYSTEM_POWER_STATUS supply{};
  GetSystemPowerStatus(&supply);
  const GUID current_mode = supply.ACLineStatus == 0 ? dc : ac;
  const std::string description = "Включает системную экономию энергии Windows. Без галочки возвращает прежнее правило автоматического включения.";
  DWORD threshold_ac=0, threshold_dc=0;
  const bool available = ReadThresholds(active,&threshold_ac,&threshold_dc);
  M thresholds;
  for (const auto& item : normal_thresholds_) thresholds.emplace(V(item.first),V(M{{V("ac"),V(static_cast<int>(item.second.ac))},{V("dc"),V(static_cast<int>(item.second.dc))}}));
  return V(M{{V("monitors"),V(monitors)}, {V("saverAvailable"),V(available)},
    {V("saverActive"),V(energy_status_.value() > 0)}, {V("energySaverStatus"),V(energy_status_.value())},
    {V("onBattery"),V(supply.ACLineStatus == 0)}, {V("batteryPercent"),V(static_cast<int>(supply.BatteryLifePercent))},
    {V("normalEnergyThresholds"),V(thresholds)},
    {V("powerName"),V(PlanName(active) + (modern ? " · " + ModeName(current_mode) : ""))},
    {V("normalPowerScheme"),V(GuidText(normal_power_))}, {V("normalAcMode"),V(GuidText(normal_ac_))},
    {V("normalDcMode"),V(GuidText(normal_dc_))}, {V("powerDescription"),V(description)}});
}
EnergyBackend::Value EnergyBackend::Apply(const M& args) {
  if (state_ == "pending") throw std::runtime_error("Сначала подтвердите предыдущие изменения.");
  const auto device = Wide(Text(args,"monitorId"));
  const int width = Integer(args,"width"), height = Integer(args,"height"), hz = Integer(args,"hz");
  const bool saver = Boolean(args,"windowsSaver");
  DEVMODEW old_mode{};
  if (device.empty() || !CurrentMode(device,&old_mode)) throw std::runtime_error("Монитор отключён или недоступен. Обновите список мониторов.");
  const auto modes = Modes(device,old_mode);
  auto found = std::find_if(modes.begin(),modes.end(),[&](const auto& mode) { return static_cast<int>(mode.dmPelsWidth) == width && static_cast<int>(mode.dmPelsHeight) == height && static_cast<int>(mode.dmDisplayFrequency) == hz; });
  if (found == modes.end()) throw std::runtime_error("Режим больше не поддерживается монитором.");
  DEVMODEW desired = *found;
  desired.dmPosition = old_mode.dmPosition;
  desired.dmFields |= DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
  const LONG test = ChangeDisplaySettingsExW(device.c_str(),&desired,nullptr,CDS_TEST,nullptr);
  if (test != DISP_CHANGE_SUCCESSFUL) throw std::runtime_error(ModeError(test));
  const GUID old_power = ActivePower();
  const auto plans = PowerPlans();
  GUID ac{}, dc{};
  const bool modern = !HasPlan(plans,kSaver) && ModernPower().Read(&ac,&dc);
  GUID normal = IsEqualGUID(old_power,kSaver) ? normal_power_ : old_power;
  if (!HasPlan(plans,normal)) {
    if (HasPlan(plans,kBalanced)) normal = kBalanced;
    else if (!saver && !modern) throw std::runtime_error("Прежний план питания недоступен. Выберите план в настройках Windows.");
  }
  const GUID desired_power = saver ? kSaver : normal;
  const GUID target_scheme = modern || (saver && !HasPlan(plans,kSaver)) ? old_power : desired_power;
  DWORD old_ac_threshold=0, old_dc_threshold=0;
  const bool have_thresholds = ReadThresholds(target_scheme,&old_ac_threshold,&old_dc_threshold);
  if (saver && !have_thresholds) throw std::runtime_error("Windows не разрешает управлять системной экономией энергии. Снимите галочку, чтобы применить параметры экрана.");
  std::optional<BrightnessInfo> brightness;
  const auto brightness_arg = args.find(V("brightness"));
  int target_brightness = -1;
  if (brightness_arg != args.end() && !std::holds_alternative<std::monostate>(brightness_arg->second)) {
    target_brightness = Integer(args,"brightness");
    brightness = MonitorBrightness(device);
    if (!brightness || std::find(brightness->levels.begin(),brightness->levels.end(),target_brightness) == brightness->levels.end()) throw std::runtime_error("Монитор не поддерживает выбранную яркость. Отключите изменение яркости или выберите доступное значение.");
  }
  device_ = device; original_ = old_mode; proposed_ = desired; original_power_ = old_power;
  previous_normal_power_ = normal_power_;
  previous_thresholds_ = normal_thresholds_;
  threshold_scheme_ = target_scheme; original_thresholds_ = {old_ac_threshold,old_dc_threshold};
  const auto threshold_key = GuidText(target_scheme);
  if (saver && normal_thresholds_.find(threshold_key) == normal_thresholds_.end()) normal_thresholds_[threshold_key] = original_thresholds_;
  const auto cached = normal_thresholds_.find(threshold_key);
  const Thresholds requested_thresholds = saver ? Thresholds{100,100} : cached != normal_thresholds_.end() ? cached->second : original_thresholds_;
  thresholds_changed_ = have_thresholds && (requested_thresholds.ac != old_ac_threshold || requested_thresholds.dc != old_dc_threshold);
  requested_saver_ = saver;
  brightness_changed_ = brightness && brightness->value != target_brightness;
  brightness_instance_ = brightness ? brightness->instance : L"";
  original_brightness_ = brightness ? brightness->value : 0;
  previous_normal_ac_ = normal_ac_; previous_normal_dc_ = normal_dc_;
  original_ac_ = ac; original_dc_ = dc; modern_power_ = modern;
  const GUID normal_ac = IsEqualGUID(ac,kEfficiency) ? normal_ac_ : ac;
  const GUID normal_dc = IsEqualGUID(dc,kEfficiency) ? normal_dc_ : dc;
  const GUID target_ac = saver ? kEfficiency : normal_ac;
  const GUID target_dc = saver ? kEfficiency : normal_dc;
  modes_changed_ = modern && (!IsEqualGUID(ac,target_ac) || !IsEqualGUID(dc,target_dc));
  display_changed_ = width != static_cast<int>(old_mode.dmPelsWidth) || height != static_cast<int>(old_mode.dmPelsHeight) || hz != static_cast<int>(old_mode.dmDisplayFrequency);
  power_changed_ = !IsEqualGUID(old_power,target_scheme);
  ++transaction_id_; state_ = "pending"; message_.clear();
  if (display_changed_) {
    const LONG code = ChangeDisplaySettingsExW(device_.c_str(),&proposed_,nullptr,0,nullptr);
    if (code != DISP_CHANGE_SUCCESSFUL) {
      const bool restored = Restore();
      throw std::runtime_error(ModeError(code) + (restored ? "" : " Автовозврат не удался; проверьте параметры экрана Windows."));
    }
  }
  if (power_changed_) {
    const auto code = PowerSetActiveScheme(nullptr,&target_scheme);
    if (code != ERROR_SUCCESS) {
      const bool restored = Restore();
      throw std::runtime_error("Windows отклонила смену плана питания (" + std::to_string(code) + ")." + (restored ? " Прежние настройки восстановлены." : " Проверьте параметры экрана и питания Windows."));
    }
  }
  const auto apply_thresholds = [&] {
    if (!thresholds_changed_) return;
    DWORD code = WriteThresholds(target_scheme,requested_thresholds.ac,requested_thresholds.dc);
    if (code == ERROR_SUCCESS) code = PowerSetActiveScheme(nullptr,&target_scheme);
    if (code != ERROR_SUCCESS) {
      const bool restored = Restore();
      throw std::runtime_error("Windows отклонила изменение системного энергосбережения (" + std::to_string(code) + ")." + (restored ? " Прежние настройки восстановлены." : " Проверьте настройки Windows."));
    }
  };
  if (!saver) apply_thresholds();
  if (modes_changed_) {
    DWORD code = ModernPower().set_ac(&target_ac);
    if (code == ERROR_SUCCESS) code = ModernPower().set_dc(&target_dc);
    if (code != ERROR_SUCCESS) {
      const bool restored = Restore();
      throw std::runtime_error("Windows отклонила смену режима питания (" + std::to_string(code) + ")." + (restored ? " Прежние настройки восстановлены." : " Проверьте параметры питания Windows."));
    }
  }
  if (saver) apply_thresholds();
  if (brightness_changed_ && !WriteBrightness(brightness_instance_,target_brightness)) {
    const bool restored = Restore();
    throw std::runtime_error(std::string("Драйвер отклонил изменение яркости.") + (restored ? " Прежние настройки восстановлены." : " Проверьте параметры экрана Windows."));
  }
  normal_power_ = normal;
  if (modern) { normal_ac_ = normal_ac; normal_dc_ = normal_dc; }
  deadline_ = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  wake_.notify_all();
  return Status();
}
EnergyBackend::Value EnergyBackend::Status() {
  int seconds = 0;
  if (state_ == "pending") {
    seconds = std::max(0,static_cast<int>(std::ceil(std::chrono::duration<double>(deadline_ - std::chrono::steady_clock::now()).count())));
    if (seconds == 0) Restore();
  }
  return V(M{{V("id"),V(transaction_id_)}, {V("state"),V(state_)}, {V("seconds"),V(seconds)}, {V("message"),V(message_)}});
}
EnergyBackend::Value EnergyBackend::Confirm(int id) {
  if (id != transaction_id_) throw std::runtime_error("Подтверждение устарело.");
  if (state_ != "pending") return Status();
  if (std::chrono::steady_clock::now() >= deadline_) { Restore(); return Status(); }
  if (display_changed_) {
    const auto code = ChangeDisplaySettingsExW(device_.c_str(),&proposed_,nullptr,CDS_UPDATEREGISTRY,nullptr);
    if (code != DISP_CHANGE_SUCCESSFUL) {
      const bool restored = Restore();
      message_ = ModeError(code) + (restored ? " Прежние настройки восстановлены." : " Автовозврат не удался; проверьте настройки Windows.");
      state_ = "failed"; return Status();
    }
  }
  state_ = "confirmed"; message_ = "Профиль применён.";
  if (requested_saver_ && energy_status_.value() <= 0) {
    SYSTEM_POWER_STATUS supply{}; GetSystemPowerStatus(&supply);
    message_ += supply.ACLineStatus == 1 ? " Системная экономия энергии настроена; Windows пока не включила её при питании от сети." : " Windows пока не подтвердила включение системной экономии энергии. Проверьте индикатор в приложении или настройки Windows.";
  }
  wake_.notify_all(); return Status();
}
EnergyBackend::Value EnergyBackend::Cancel(int id) {
  if (id == transaction_id_ && state_ == "pending") Restore();
  return Status();
}
bool EnergyBackend::Restore() {
  bool ok = true;
  if (display_changed_) ok = ChangeDisplaySettingsExW(device_.c_str(),&original_,nullptr,CDS_UPDATEREGISTRY,nullptr) == DISP_CHANGE_SUCCESSFUL;
  if (thresholds_changed_) {
    const auto code = WriteThresholds(threshold_scheme_,original_thresholds_.ac,original_thresholds_.dc);
    ok = (code == ERROR_SUCCESS) && ok;
    ok = (PowerSetActiveScheme(nullptr,&original_power_) == ERROR_SUCCESS) && ok;
  }
  if (power_changed_) ok = (PowerSetActiveScheme(nullptr,&original_power_) == ERROR_SUCCESS) && ok;
  if (modern_power_ && modes_changed_) {
    const bool ac_ok = ModernPower().set_ac(&original_ac_) == ERROR_SUCCESS;
    const bool dc_ok = ModernPower().set_dc(&original_dc_) == ERROR_SUCCESS;
    ok = ok && ac_ok && dc_ok;
  }
  normal_power_ = previous_normal_power_;
  normal_thresholds_ = previous_thresholds_;
  if (brightness_changed_) ok = WriteBrightness(brightness_instance_,original_brightness_) && ok;
  normal_ac_ = previous_normal_ac_; normal_dc_ = previous_normal_dc_;
  state_ = ok ? "reverted" : "failed";
  message_ = ok ? "Прежние настройки восстановлены." : "Не удалось полностью восстановить настройки. Проверьте параметры экрана и питания Windows.";
  wake_.notify_all(); return ok;
}
void EnergyBackend::Watchdog() {
  const HRESULT com = CoInitializeEx(nullptr,COINIT_MULTITHREADED);
  std::unique_lock<std::mutex> lock(mutex_);
  while (!stopping_) {
    wake_.wait(lock,[this] { return stopping_ || state_ == "pending"; });
    if (stopping_) break;
    const int observed_id = transaction_id_;
    if (!wake_.wait_until(lock,deadline_,[this,observed_id] { return stopping_ || state_ != "pending" || transaction_id_ != observed_id; })) Restore();
  }
  lock.unlock();
  if (SUCCEEDED(com)) CoUninitialize();
}
int EnergyBackend::Diagnostics() {
  EnergySaverStatus saver_status;
  Sleep(100);
  std::string report; int count = 0; bool ok = true;
  try {
    report += "Power plan: " + PlanName(ActivePower()) + "\r\n";
    report += "Actual energy saver: " + std::to_string(saver_status.value()) + "\r\n";
    report += std::string("Power saver available: ") + (HasPlan(PowerPlans(),kSaver) ? "yes\r\n" : "no\r\n");
    GUID ac{}, dc{};
    const bool modern = ModernPower().Read(&ac,&dc);
    report += std::string("Modern power control: ") + (modern ? "yes\r\n" : "no\r\n");
    if (modern) report += "AC: " + ModeName(ac) + "; DC: " + ModeName(dc) + "\r\n";
    for (DWORD i = 0;; ++i) {
      DISPLAY_DEVICEW adapter{}; adapter.cb = sizeof(adapter);
      if (!EnumDisplayDevicesW(nullptr,i,&adapter,0)) break;
      if (!(adapter.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) continue;
      DEVMODEW current{};
      if (!CurrentMode(adapter.DeviceName,&current)) { ok = false; continue; }
      ++count;
      const auto modes = Modes(adapter.DeviceName,current);
      const auto brightness = MonitorBrightness(adapter.DeviceName);
      report += "Brightness: " + (brightness ? std::to_string(brightness->value) + "%" : "unavailable") + "\r\n";
      const auto test = ChangeDisplaySettingsExW(adapter.DeviceName,&current,nullptr,CDS_TEST,nullptr);
      ok = ok && !modes.empty() && test == DISP_CHANGE_SUCCESSFUL;
      report += Utf8(adapter.DeviceName) + ": " + std::to_string(current.dmPelsWidth) + "x" + std::to_string(current.dmPelsHeight) + " @ " + std::to_string(current.dmDisplayFrequency) + " Hz; modes=" + std::to_string(modes.size()) + "; CDS_TEST=" + std::to_string(test) + "\r\n";
    }
    ok = ok && count > 0;
  } catch (const std::exception& error) { report += error.what(); ok = false; }
  report += ok ? "READ_ONLY_CHECK_PASSED\r\n" : "READ_ONLY_CHECK_FAILED\r\n";
  DWORD written = 0;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),report.data(),static_cast<DWORD>(report.size()),&written,nullptr);
  return ok ? 0 : 1;
}

