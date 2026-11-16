import 'dart:io';
import 'package:energy_profiles/main.dart';
import 'package:energy_profiles/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const display = DisplayMonitor(
  id: 'display1',
  name: 'Test Monitor',
  primary: true,
  current: DisplayMode(1920, 1080, 144),
  modes: [
    DisplayMode(1280, 720, 60),
    DisplayMode(1920, 1080, 60),
    DisplayMode(1920, 1080, 144),
  ],
);
const testSystem = SystemSnapshot(
  monitors: [display],
  saverAvailable: true,
  saverActive: false,
  powerName: 'Сбалансированный',
  normalPowerScheme: '{381b4222-f694-41f0-9685-ff5bb260df2e}',
);

class MemoryStore extends SettingsStore {
  MemoryStore() : super(Directory('unused'));
  AppSettings? settings;
  @override
  Future<AppSettings?> read() async => settings;
  @override
  Future<void> write(AppSettings value) async {
    settings = value;
  }
}

class FakeApi extends WindowsApi {
  int applied = 0, confirmed = 0, cancelled = 0;
  bool expire = false;
  @override
  Future<SystemSnapshot> snapshot() async => snapshotValue;
  SystemSnapshot get snapshotValue => testSystem;
  @override
  Future<void> configure(AppSettings value) async {}
  @override
  Future<TransactionStatus> apply(EnergyProfile profile) async {
    applied++;
    return const TransactionStatus(1, 'pending', 15, '');
  }

  @override
  Future<TransactionStatus> status() async => expire
      ? const TransactionStatus(
          1,
          'reverted',
          0,
          'Прежние настройки восстановлены.',
        )
      : const TransactionStatus(1, 'pending', 14, '');
  @override
  Future<TransactionStatus> confirm(int id) async {
    confirmed++;
    return const TransactionStatus(1, 'confirmed', 0, 'Профиль применён.');
  }

  @override
  Future<TransactionStatus> cancel(int id) async {
    cancelled++;
    return const TransactionStatus(
      1,
      'reverted',
      0,
      'Прежние настройки восстановлены.',
    );
  }
}

void main() {
  test('Battery estimate handles units and missing discharge', () {
    const battery = BatteryStats(
      dischargeMilliwatts: 7980,
      remainingMilliwattHours: 50689,
    );
    expect(battery.dischargeWatts, 7.98);
    expect(battery.remainingWh, 50.689);
    expect(battery.estimatedMinutes, 381);
    expect(
      const BatteryStats(
        dischargeMilliwatts: 0,
        remainingMilliwattHours: 50000,
      ).estimatedMinutes,
      isNull,
    );
    expect(const BatteryStats().estimatedMinutes, isNull);
  });
  test('Brightness survives saving and older profiles remain compatible', () {
    final profiles = defaultProfiles(testSystem);
    final changed = profiles.first.copyWith(brightness: 35);
    final settings = AppSettings([
      changed,
      ...profiles.skip(1),
    ], testSystem.normalPowerScheme);
    expect(AppSettings.decode(settings.encode()).profiles.first.brightness, 35);
    expect(changed.copyWith(clearBrightness: true).brightness, isNull);
    final legacy = profiles.first.toJson()..remove('brightness');
    expect(EnergyProfile.fromMap(legacy).brightness, isNull);
    expect(
      () => EnergyProfile.fromMap({...legacy, 'brightness': 101}),
      throwsFormatException,
    );
  });
  test('Original Windows automatic saver thresholds survive saving', () {
    final settings = AppSettings(
      defaultProfiles(testSystem),
      testSystem.normalPowerScheme,
      normalEnergyThresholds: {
        testSystem.normalPowerScheme: {'ac': 0, 'dc': 30},
      },
    );
    expect(
      AppSettings.decode(settings.encode()).normalEnergyThresholds,
      settings.normalEnergyThresholds,
    );
  });
  test(
    'Defaults use supported modes and the requested three fixed profiles',
    () {
      final profiles = defaultProfiles(testSystem);
      expect(profiles.map((p) => p.name), [
        'Суперэкономия',
        'Экономия',
        'Плавность',
      ]);
      expect(profiles.every((p) => p.supported(testSystem)), isTrue);
      expect(profiles[0].mode, const DisplayMode(1280, 720, 60));
      expect(profiles[1].mode, const DisplayMode(1920, 1080, 60));
      expect(profiles[2].mode, const DisplayMode(1920, 1080, 144));
      expect(profiles.map((p) => p.windowsSaver), [true, true, false]);
    },
  );
  test('Unavailable monitors and refresh rates cannot be applied', () {
    final profile = defaultProfiles(testSystem).first;
    expect(
      profile.copyWith(monitorId: 'disconnected').supported(testSystem),
      isFalse,
    );
    expect(
      profile
          .copyWith(mode: const DisplayMode(1920, 1080, 240))
          .supported(testSystem),
      isFalse,
    );
  });
  test('Settings round-trip and reject missing or duplicate profiles', () {
    final settings = AppSettings(
      defaultProfiles(testSystem),
      testSystem.normalPowerScheme,
    );
    expect(AppSettings.decode(settings.encode()).profiles, settings.profiles);
    expect(
      AppSettings.decode(settings.encode()).normalPowerScheme,
      testSystem.normalPowerScheme,
    );
    final duplicate = AppSettings([
      settings.profiles.first,
      settings.profiles.first,
      settings.profiles.last,
    ], '');
    expect(() => AppSettings.decode(duplicate.encode()), throwsFormatException);
    expect(() => AppSettings.decode('{"version":2}'), throwsFormatException);
  });
  test('Atomic settings save and recovery keep a valid backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'energy_profiles_test_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = SettingsStore(directory);
    final first = AppSettings(
      defaultProfiles(testSystem),
      testSystem.normalPowerScheme,
    );
    await store.write(first);
    await store.write(
      AppSettings([
        first.profiles[0].copyWith(windowsSaver: false),
        ...first.profiles.skip(1),
      ], first.normalPowerScheme),
    );
    expect((await store.read())!.profiles.first.windowsSaver, isFalse);
    await store.file.writeAsString('broken');
    expect((await store.read())!.profiles, first.profiles);
    expect(store.recovered, isTrue);
    await store.write(first);
    expect((await store.read())!.profiles, first.profiles);
    expect(
      AppSettings.decode(await store.backup.readAsString()).profiles,
      first.profiles,
    );
  });
  testWidgets('Checkbox is saved independently for a profile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1120, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = MemoryStore();
    await tester.pumpWidget(EnergyApp(store: store, api: FakeApi()));
    await tester.pumpAndSettle();
    expect(find.text('Суперэкономия'), findsOneWidget);
    expect(find.text('Экономия'), findsOneWidget);
    expect(find.text('Плавность'), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.text('Энергосбережение Windows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить профиль'));
    await tester.pumpAndSettle();
    expect(store.settings!.profiles.first.windowsSaver, isFalse);
    expect(store.settings!.profiles[1].windowsSaver, isTrue);
    expect(tester.takeException(), isNull);
  });
  for (final action in ['confirm', 'cancel', 'timeout']) {
    testWidgets('Applying a profile handles $action', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1120, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = FakeApi();
      await tester.pumpWidget(EnergyApp(store: MemoryStore(), api: api));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Применить').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Сохранить эти настройки?'), findsOneWidget);
      if (action == 'timeout') {
        api.expire = true;
        await tester.pump(const Duration(seconds: 1));
      } else {
        await tester.tap(
          find.text(action == 'confirm' ? 'Подтвердить' : 'Вернуть как было'),
        );
      }
      await tester.pumpAndSettle();
      expect(api.applied, 1);
      expect(api.confirmed, action == 'confirm' ? 1 : 0);
      expect(api.cancelled, action == 'cancel' ? 1 : 0);
      expect(find.text('Сохранить эти настройки?'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Layout works at minimum window width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(780, 580));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(EnergyApp(store: MemoryStore(), api: FakeApi()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Энергосбережение Windows'));
    expect(tester.takeException(), isNull);
  });
}
