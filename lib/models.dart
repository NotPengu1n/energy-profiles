import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

typedef Json = Map<String, dynamic>;
typedef ThresholdMap = Map<String, Map<String, int>>;
ThresholdMap readThresholds(dynamic data) {
  if (data == null) return {};
  return (data as Map).map((key, value) {
    final item = value as Map;
    final ac = item['ac'] as int, dc = item['dc'] as int;
    if (ac < 0 || ac > 100 || dc < 0 || dc > 100) {
      throw const FormatException('Некорректные параметры экономии энергии.');
    }
    return MapEntry(key as String, {'ac': ac, 'dc': dc});
  });
}

class DisplayMode {
  const DisplayMode(this.width, this.height, this.hz);
  final int width, height, hz;
  String get resolution => '$width × $height';
  int get pixels => width * height;
  factory DisplayMode.fromMap(Map<dynamic, dynamic> data) {
    final mode = DisplayMode(
      data['width'] as int,
      data['height'] as int,
      data['hz'] as int,
    );
    if (mode.width <= 0 || mode.height <= 0 || mode.hz < 0) {
      throw const FormatException('Некорректный режим экрана.');
    }
    return mode;
  }
  Json toJson() => {'width': width, 'height': height, 'hz': hz};
  @override
  bool operator ==(Object other) =>
      other is DisplayMode &&
      width == other.width &&
      height == other.height &&
      hz == other.hz;
  @override
  int get hashCode => Object.hash(width, height, hz);
}

class DisplayMonitor {
  const DisplayMonitor({
    required this.id,
    required this.name,
    required this.primary,
    required this.current,
    required this.modes,
    this.brightness,
    this.brightnessLevels = const [],
  });
  final String id, name;
  final bool primary;
  final DisplayMode current;
  final List<DisplayMode> modes;
  final int? brightness;
  final List<int> brightnessLevels;
  int nearestBrightness(int value) {
    if (brightnessLevels.isEmpty) return value;
    return brightnessLevels.reduce(
      (a, b) => (a - value).abs() <= (b - value).abs() ? a : b,
    );
  }

  String get label => '$name · $id${primary ? ' · основной' : ''}';
  factory DisplayMonitor.fromMap(Map<dynamic, dynamic> data) => DisplayMonitor(
    id: data['id'] as String,
    name: data['name'] as String,
    primary: data['primary'] as bool,
    current: DisplayMode.fromMap(data['current'] as Map),
    brightness: data['brightness'] as int?,
    brightnessLevels: (data['brightnessLevels'] as List? ?? []).cast<int>(),
    modes: (data['modes'] as List)
        .map((item) => DisplayMode.fromMap(item as Map))
        .toSet()
        .toList(),
  );
  List<String> get resolutions {
    final sorted = [...modes]..sort((a, b) => b.pixels.compareTo(a.pixels));
    return sorted.map((mode) => mode.resolution).toSet().toList();
  }

  List<DisplayMode> atResolution(String resolution) =>
      modes.where((mode) => mode.resolution == resolution).toList()
        ..sort((a, b) => a.hz.compareTo(b.hz));
}

class SystemSnapshot {
  const SystemSnapshot({
    required this.monitors,
    required this.saverAvailable,
    required this.saverActive,
    required this.powerName,
    required this.normalPowerScheme,
    this.normalAcMode = '',
    this.normalDcMode = '',
    this.normalEnergyThresholds = const {},
    this.onBattery = false,
    this.batteryPercent = 255,
    this.energySaverStatus = 0,
    this.powerDescription =
        'Включает план «Экономия энергии». Без галочки возвращает прежний план питания.',
  });
  final List<DisplayMonitor> monitors;
  final bool saverAvailable, saverActive;
  final String powerName, normalPowerScheme;
  final String normalAcMode, normalDcMode, powerDescription;
  final ThresholdMap normalEnergyThresholds;
  final bool onBattery;
  final int batteryPercent, energySaverStatus;
  factory SystemSnapshot.fromMap(Map<dynamic, dynamic> data) => SystemSnapshot(
    monitors: (data['monitors'] as List)
        .map((item) => DisplayMonitor.fromMap(item as Map))
        .toList(),
    saverAvailable: data['saverAvailable'] as bool,
    saverActive: data['saverActive'] as bool,
    powerName: data['powerName'] as String,
    normalPowerScheme: data['normalPowerScheme'] as String,
    normalAcMode: data['normalAcMode'] as String? ?? '',
    normalDcMode: data['normalDcMode'] as String? ?? '',
    normalEnergyThresholds: readThresholds(data['normalEnergyThresholds']),
    onBattery: data['onBattery'] as bool? ?? false,
    batteryPercent: data['batteryPercent'] as int? ?? 255,
    energySaverStatus: data['energySaverStatus'] as int? ?? -1,
    powerDescription: data['powerDescription'] as String? ?? '',
  );
  DisplayMonitor? monitor(String id) =>
      monitors.where((item) => item.id == id).firstOrNull;
}

const profileNames = {
  'super': 'Суперэкономия',
  'eco': 'Экономия',
  'performance': 'Производительность',
};

class EnergyProfile {
  const EnergyProfile({
    required this.id,
    required this.monitorId,
    required this.mode,
    required this.windowsSaver,
    this.brightness,
  });
  final String id, monitorId;
  final DisplayMode mode;
  final bool windowsSaver;
  final int? brightness;
  String get name => profileNames[id]!;
  EnergyProfile copyWith({
    String? monitorId,
    DisplayMode? mode,
    bool? windowsSaver,
    int? brightness,
    bool clearBrightness = false,
  }) => EnergyProfile(
    id: id,
    monitorId: monitorId ?? this.monitorId,
    mode: mode ?? this.mode,
    windowsSaver: windowsSaver ?? this.windowsSaver,
    brightness: clearBrightness ? null : brightness ?? this.brightness,
  );
  factory EnergyProfile.fromMap(Map<dynamic, dynamic> data) {
    final id = data['id'] as String;
    final monitorId = data['monitorId'] as String;
    if (!profileNames.containsKey(id) || monitorId.isEmpty) {
      throw const FormatException('Неизвестный профиль или монитор.');
    }
    final brightness = data['brightness'] as int?;
    if (brightness != null && (brightness < 0 || brightness > 100)) {
      throw const FormatException('Яркость должна быть от 0 до 100%.');
    }
    return EnergyProfile(
      id: id,
      monitorId: monitorId,
      mode: DisplayMode.fromMap(data),
      windowsSaver: data['windowsSaver'] as bool,
      brightness: brightness,
    );
  }
  Json toJson() => {
    'id': id,
    'monitorId': monitorId,
    ...mode.toJson(),
    'windowsSaver': windowsSaver,
    'brightness': brightness,
  };
  bool supported(SystemSnapshot system) =>
      (system.monitor(monitorId)?.modes.contains(mode) ?? false) &&
      (brightness == null ||
          (system.monitor(monitorId)?.brightnessLevels.contains(brightness) ??
              false));
  bool matches(SystemSnapshot system) =>
      system.monitor(monitorId)?.current == mode &&
      windowsSaver == system.saverActive &&
      (brightness == null ||
          brightness == system.monitor(monitorId)?.brightness);
  @override
  bool operator ==(Object other) =>
      other is EnergyProfile &&
      id == other.id &&
      monitorId == other.monitorId &&
      mode == other.mode &&
      windowsSaver == other.windowsSaver &&
      brightness == other.brightness;
  @override
  int get hashCode =>
      Object.hash(id, monitorId, mode, windowsSaver, brightness);
}

List<EnergyProfile> defaultProfiles(SystemSnapshot system) {
  if (system.monitors.isEmpty) {
    throw StateError('Windows не обнаружила доступных мониторов.');
  }
  final monitor =
      system.monitors.where((item) => item.primary).firstOrNull ??
      system.monitors.first;
  final current = monitor.current;
  DisplayMode lowestRate(List<DisplayMode> modes) {
    final usable = modes.where((item) => item.hz >= 50).toList();
    final candidates = usable.isEmpty ? [...modes] : usable;
    candidates.sort((a, b) => a.hz.compareTo(b.hz));
    return candidates.first;
  }

  // Keep the aspect ratio and avoid tiny or cinematic 24/30 Hz defaults.
  final smaller =
      monitor.modes
          .where(
            (mode) =>
                mode.width >= 1280 &&
                mode.height >= 720 &&
                mode.pixels <= current.pixels &&
                (mode.width / mode.height - current.width / current.height)
                        .abs() <
                    0.04,
          )
          .toList()
        ..sort((a, b) => a.pixels.compareTo(b.pixels));
  final smallResolution = smaller.isEmpty
      ? current.resolution
      : smaller.first.resolution;
  final sameResolution = monitor.atResolution(current.resolution);
  return [
    EnergyProfile(
      id: 'super',
      monitorId: monitor.id,
      mode: lowestRate(monitor.atResolution(smallResolution)),
      windowsSaver: true,
      brightness: monitor.brightness == null
          ? null
          : monitor.nearestBrightness(30),
    ),
    EnergyProfile(
      id: 'eco',
      monitorId: monitor.id,
      mode: lowestRate(sameResolution),
      windowsSaver: true,
      brightness: monitor.brightness == null
          ? null
          : monitor.nearestBrightness(50),
    ),
    EnergyProfile(
      id: 'performance',
      monitorId: monitor.id,
      mode: sameResolution.last,
      windowsSaver: false,
      brightness: monitor.brightness == null
          ? null
          : monitor.nearestBrightness(80),
    ),
  ];
}

class AppSettings {
  const AppSettings(
    this.profiles,
    this.normalPowerScheme, {
    this.normalAcMode = '',
    this.normalDcMode = '',
    this.normalEnergyThresholds = const {},
  });
  final List<EnergyProfile> profiles;
  final String normalPowerScheme;
  final String normalAcMode, normalDcMode;
  final ThresholdMap normalEnergyThresholds;
  factory AppSettings.capture(
    List<EnergyProfile> profiles,
    SystemSnapshot system,
  ) => AppSettings(
    profiles,
    system.normalPowerScheme,
    normalAcMode: system.normalAcMode,
    normalDcMode: system.normalDcMode,
    normalEnergyThresholds: system.normalEnergyThresholds,
  );
  factory AppSettings.decode(String text) {
    final data = jsonDecode(text) as Map;
    if (data['version'] != 1) {
      throw const FormatException('Неизвестная версия файла настроек.');
    }
    final profiles = (data['profiles'] as List)
        .map((item) => EnergyProfile.fromMap(item as Map))
        .toList();
    if (profiles.length != 3 ||
        profiles.map((item) => item.id).toSet().length != 3) {
      throw const FormatException('В файле должны быть три разных профиля.');
    }
    final ordered = profileNames.keys
        .map((id) => profiles.singleWhere((item) => item.id == id))
        .toList();
    return AppSettings(
      ordered,
      data['normalPowerScheme'] as String,
      normalAcMode: data['normalAcMode'] as String? ?? '',
      normalDcMode: data['normalDcMode'] as String? ?? '',
      normalEnergyThresholds: readThresholds(data['normalEnergyThresholds']),
    );
  }
  String encode() => const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'normalPowerScheme': normalPowerScheme,
    'normalAcMode': normalAcMode,
    'normalDcMode': normalDcMode,
    'normalEnergyThresholds': normalEnergyThresholds,
    'profiles': profiles.map((item) => item.toJson()).toList(),
  });
}

class SettingsStore {
  SettingsStore(this.directory);
  final Directory directory;
  bool recovered = false;
  File get file =>
      File('${directory.path}${Platform.pathSeparator}profiles.json');
  File get backup => File('${file.path}.bak');
  static SettingsStore local() {
    final root = Platform.environment['LOCALAPPDATA'];
    if (root == null) {
      throw StateError('Windows не предоставила папку LOCALAPPDATA.');
    }
    return SettingsStore(
      Directory('$root${Platform.pathSeparator}EnergyProfiles'),
    );
  }

  Future<AppSettings?> read() async {
    if (!await file.exists() && !await backup.exists()) return null;
    try {
      return AppSettings.decode(await file.readAsString());
    } catch (_) {
      if (await backup.exists()) {
        final settings = AppSettings.decode(await backup.readAsString());
        recovered = true;
        return settings;
      }
      rethrow;
    }
  }

  Future<void> write(AppSettings settings) async {
    await directory.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(settings.encode(), flush: true);
    // Never replace a good backup with the damaged primary file.
    if (await file.exists() && !recovered) await file.copy(backup.path);
    await temporary.rename(file.path);
    recovered = false;
  }
}

class TransactionStatus {
  const TransactionStatus(this.id, this.state, this.seconds, this.message);
  final int id, seconds;
  final String state, message;
  bool get pending => state == 'pending';
  bool get confirmed => state == 'confirmed';
  factory TransactionStatus.fromMap(Map<dynamic, dynamic> data) =>
      TransactionStatus(
        data['id'] as int,
        data['state'] as String,
        data['seconds'] as int,
        data['message'] as String,
      );
}

class WindowsApi {
  const WindowsApi();
  static const channel = MethodChannel('app.energy/profiles');
  Future<SystemSnapshot> snapshot() async =>
      SystemSnapshot.fromMap((await channel.invokeMethod<Map>('snapshot'))!);
  Future<void> configure(AppSettings settings) =>
      channel.invokeMethod('configure', {
        'normalPowerScheme': settings.normalPowerScheme,
        'normalAcMode': settings.normalAcMode,
        'normalDcMode': settings.normalDcMode,
        'normalEnergyThresholds': settings.normalEnergyThresholds,
      });
  Future<TransactionStatus> apply(EnergyProfile profile) async =>
      TransactionStatus.fromMap(
        (await channel.invokeMethod<Map>('apply', profile.toJson()))!,
      );
  Future<void> openPowerSettings() => channel.invokeMethod('openPowerSettings');
  Future<TransactionStatus> status() async =>
      TransactionStatus.fromMap((await channel.invokeMethod<Map>('status'))!);
  Future<TransactionStatus> confirm(int id) async => TransactionStatus.fromMap(
    (await channel.invokeMethod<Map>('confirm', {'id': id}))!,
  );
  Future<TransactionStatus> cancel(int id) async => TransactionStatus.fromMap(
    (await channel.invokeMethod<Map>('cancel', {'id': id}))!,
  );
}
