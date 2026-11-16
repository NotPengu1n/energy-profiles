#include "system_controls.h"
#include <powrprof.h>
#include <wbemidl.h>
#include <wrl/client.h>
#include <algorithm>
#include <cwctype>
#include <cstring>
#include <stdexcept>

EnergySaverStatus::EnergySaverStatus() {
  DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS parameters{Callback,this};
  if (PowerSettingRegisterNotification(&GUID_ENERGY_SAVER_STATUS,DEVICE_NOTIFY_CALLBACK,&parameters,&notification_) != ERROR_SUCCESS) {
    notification_ = nullptr;
    PowerSettingRegisterNotification(&GUID_POWER_SAVING_STATUS,DEVICE_NOTIFY_CALLBACK,&parameters,&notification_);
  }
}
EnergySaverStatus::~EnergySaverStatus() {
  if (notification_) PowerSettingUnregisterNotification(notification_);
}
ULONG CALLBACK EnergySaverStatus::Callback(PVOID context, ULONG, PVOID data) {
  const auto* setting = static_cast<const POWERBROADCAST_SETTING*>(data);
  if (setting && setting->DataLength >= sizeof(DWORD)) {
    DWORD value = 0;
    std::memcpy(&value,setting->Data,sizeof(value));
    static_cast<EnergySaverStatus*>(context)->state_.store(static_cast<int>(value));
  }
  return ERROR_SUCCESS;
}
int EnergySaverStatus::value() const {
  const int current = state_.load();
  if (current >= 0) return current;
  SYSTEM_POWER_STATUS power{};
  if (GetSystemPowerStatus(&power)) return power.SystemStatusFlag ? 1 : 0;
  return -1;
}

namespace {
using Microsoft::WRL::ComPtr;
class String {
 public:
  explicit String(const wchar_t* text) : value_(SysAllocString(text)) {}
  ~String() { SysFreeString(value_); }
  operator BSTR() const { return value_; }
 private:
  BSTR value_;
};
void Check(HRESULT code) { if (FAILED(code)) throw std::runtime_error("WMI brightness error"); }
class Wmi {
 public:
  Wmi() {
    ComPtr<IWbemLocator> locator;
    Check(CoCreateInstance(CLSID_WbemLocator,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&locator)));
    Check(locator->ConnectServer(String(L"ROOT\\WMI"),nullptr,nullptr,nullptr,0,nullptr,nullptr,&services));
    Check(CoSetProxyBlanket(services.Get(),RPC_C_AUTHN_WINNT,RPC_C_AUTHZ_NONE,nullptr,RPC_C_AUTHN_LEVEL_CALL,RPC_C_IMP_LEVEL_IMPERSONATE,nullptr,EOAC_NONE));
  }
  ComPtr<IEnumWbemClassObject> Query(const wchar_t* query) {
    ComPtr<IEnumWbemClassObject> rows;
    Check(services->ExecQuery(String(L"WQL"),String(query),WBEM_FLAG_FORWARD_ONLY | WBEM_FLAG_RETURN_IMMEDIATELY,nullptr,&rows));
    return rows;
  }
  ComPtr<IWbemServices> services;
};
std::wstring Property(IWbemClassObject* row, const wchar_t* key) {
  VARIANT data; VariantInit(&data);
  const auto code = row->Get(key,0,&data,nullptr,nullptr);
  std::wstring value = SUCCEEDED(code) && data.vt == VT_BSTR && data.bstrVal ? data.bstrVal : L"";
  VariantClear(&data);
  return value;
}
std::wstring Identity(std::wstring value) {
  std::transform(value.begin(),value.end(),value.begin(),[](wchar_t c) { return static_cast<wchar_t>(std::towupper(c)); });
  if (value.find(L"\\\\?\\") == 0) value.erase(0,4);
  std::replace(value.begin(),value.end(),L'#',L'\\');
  const auto suffix = value.find(L"\\{");
  if (suffix != std::wstring::npos) value.resize(suffix);
  return value;
}
}

std::optional<BrightnessInfo> ReadBrightness(const std::wstring& monitor_interface) {
  try {
    Wmi wmi;
    auto rows = wmi.Query(L"SELECT * FROM WmiMonitorBrightness WHERE Active=TRUE");
    const auto identity = Identity(monitor_interface);
    for (;;) {
      ComPtr<IWbemClassObject> row; ULONG count = 0;
      Check(rows->Next(2000,1,&row,&count));
      if (!count) break;
      const auto instance = Property(row.Get(),L"InstanceName");
      auto key = Identity(instance);
      if (key.size() >= 2 && key[key.size()-2] == L'_') key.resize(key.size()-2);
      if (identity.empty() || key != identity) continue;
      VARIANT current; VariantInit(&current);
      Check(row->Get(L"CurrentBrightness",0,&current,nullptr,nullptr));
      VARIANT converted; VariantInit(&converted);
      const HRESULT code = VariantChangeType(&converted,&current,0,VT_I4);
      VariantClear(&current);
      Check(code);
      const int value = converted.lVal;
      VariantClear(&converted);
      VARIANT levels; VariantInit(&levels);
      Check(row->Get(L"Level",0,&levels,nullptr,nullptr));
      std::vector<int> available;
      if (levels.vt == (VT_ARRAY | VT_UI1) && levels.parray) {
        LONG start = 0, end = -1;
        SafeArrayGetLBound(levels.parray,1,&start); SafeArrayGetUBound(levels.parray,1,&end);
        for (LONG i=start;i<=end;++i) {
          BYTE item = 0;
          if (SUCCEEDED(SafeArrayGetElement(levels.parray,&i,&item))) available.push_back(item);
        }
      }
      VariantClear(&levels);
      if (available.empty()) available.push_back(value);
      std::sort(available.begin(),available.end());
      return BrightnessInfo{instance,value,available};
    }
  } catch (...) { /* Unsupported drivers expose no usable brightness control. */ }
  return std::nullopt;
}

bool WriteBrightness(const std::wstring& instance, int value) {
  if (value < 0 || value > 100) return false;
  try {
    Wmi wmi;
    auto rows = wmi.Query(L"SELECT * FROM WmiMonitorBrightnessMethods WHERE Active=TRUE");
    for (;;) {
      ComPtr<IWbemClassObject> row; ULONG count=0;
      Check(rows->Next(2000,1,&row,&count));
      if (!count) break;
      if (Property(row.Get(),L"InstanceName") != instance) continue;
      const auto path = Property(row.Get(),L"__PATH");
      ComPtr<IWbemClassObject> type, signature, input, output;
      Check(wmi.services->GetObject(String(L"WmiMonitorBrightnessMethods"),0,nullptr,&type,nullptr));
      Check(type->GetMethod(L"WmiSetBrightness",0,&signature,nullptr));
      if (!signature) return false;
      Check(signature->SpawnInstance(0,&input));
      VARIANT brightness; VariantInit(&brightness); brightness.vt=VT_UI1; brightness.bVal=static_cast<BYTE>(value);
      Check(input->Put(L"Brightness",0,&brightness,0));
      VARIANT timeout; VariantInit(&timeout); timeout.vt=VT_BSTR; timeout.bstrVal=SysAllocString(L"0");
      const HRESULT parameter = input->Put(L"Timeout",0,&timeout,0); VariantClear(&timeout); Check(parameter);
      Check(wmi.services->ExecMethod(String(path.c_str()),String(L"WmiSetBrightness"),0,nullptr,input.Get(),&output,nullptr));
      VARIANT result; VariantInit(&result);
      if (!output) return true;
      const HRESULT returned = output->Get(L"ReturnValue",0,&result,nullptr,nullptr);
      if (returned == WBEM_E_NOT_FOUND) return true;
      Check(returned);
      VARIANT number; VariantInit(&number);
      const auto code=VariantChangeType(&number,&result,0,VT_I4); VariantClear(&result); Check(code);
      const bool success=number.lVal==0; VariantClear(&number);
      return success;
    }
  } catch (...) {}
  return false;
}


