import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models.dart';

const background = Color(0xFF10151C);
const surface = Color(0xFF19212B);
const muted = Color(0xFF9AA9BA);
const accent = Color(0xFF8DE5BC);
const profileColors = [Color(0xFF8DE5BC), Color(0xFF8ECBF4), Color(0xFFEAB98E)];
const profileIcons = [
  Icons.battery_saver_outlined,
  Icons.eco_outlined,
  Icons.bolt_rounded,
];
const profileDescriptions = [
  'Меньше разрешение, ниже частота',
  'Чёткое изображение, спокойный темп',
  'Полная частота для плавной работы',
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(EnergyApp(store: SettingsStore.local()));
}

class EnergyApp extends StatelessWidget {
  const EnergyApp({
    super.key,
    required this.store,
    this.api = const WindowsApi(),
  });
  final SettingsStore store;
  final WindowsApi api;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Энергопрофили',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Segoe UI',
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        surface: surface,
        secondary: accent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF344150)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF344150)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 17,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    ),
    home: ProfilesPage(store: store, api: api),
  );
}

String errorText(Object error) => error is PlatformException
    ? error.message ?? 'Ошибка Windows.'
    : error.toString();

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key, required this.store, required this.api});
  final SettingsStore store;
  final WindowsApi api;
  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  SystemSnapshot? system;
  List<EnergyProfile> saved = [], drafts = [];
  int selected = 0;
  bool busy = true;
  String? failure;
  Timer? statusTimer;
  bool polling = false;

  @override
  void initState() {
    super.initState();
    initialize();
    statusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => pollSystem(),
    );
  }

  @override
  void dispose() {
    statusTimer?.cancel();
    super.dispose();
  }

  Future<void> pollSystem() async {
    if (busy || polling || system == null) return;
    polling = true;
    try {
      final snapshot = await widget.api.snapshot();
      if (mounted && !busy) setState(() => system = snapshot);
    } catch (_) {
      /* Keep the last known state; manual refresh reports errors. */
    } finally {
      polling = false;
    }
  }

  Future<void> initialize() async {
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      final stored = await widget.store.read();
      if (stored != null) await widget.api.configure(stored);
      final snapshot = await widget.api.snapshot();
      final profiles = stored?.profiles ?? defaultProfiles(snapshot);
      final recovered = widget.store.recovered;
      if (stored == null) {
        await widget.store.write(AppSettings.capture(profiles, snapshot));
      }
      if (!mounted) return;
      setState(() {
        system = snapshot;
        saved = [...profiles];
        drafts = [...profiles];
      });
      if (recovered) {
        notify(
          'Настройки восстановлены из резервной копии. Сохраните профиль, чтобы восстановить основной файл.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => failure = errorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
      );
  }

  Future<void> refresh() async {
    setState(() => busy = true);
    try {
      final snapshot = await widget.api.snapshot();
      if (mounted) setState(() => system = snapshot);
    } catch (error) {
      notify(errorText(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void edit(EnergyProfile profile) =>
      setState(() => drafts[selected] = profile);

  Future<void> persistProfile(int index) async {
    final next = [...saved];
    next[index] = drafts[index];
    await widget.store.write(AppSettings.capture(next, system!));
    if (mounted) setState(() => saved = next);
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      await persistProfile(selected);
      notify('Профиль «${drafts[selected].name}» сохранён.');
    } catch (error) {
      notify('Не удалось сохранить профиль: ${errorText(error)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> applyProfile(int index) async {
    final profile = drafts[index];
    if (!profile.supported(system!)) {
      notify('Выберите доступный монитор и поддерживаемый режим.');
      return;
    }
    setState(() {
      busy = true;
      selected = index;
    });
    TransactionStatus? transaction;
    String? resultMessage;
    try {
      await persistProfile(index);
      transaction = await widget.api.apply(profile);
      final pendingSnapshot = await widget.api.snapshot();
      await widget.store.write(AppSettings.capture(saved, pendingSnapshot));
      if (!mounted) {
        await widget.api.cancel(transaction.id);
        return;
      }
      final outcome = transaction.pending
          ? await showDialog<TransactionStatus>(
              context: context,
              barrierDismissible: false,
              builder: (_) =>
                  ConfirmationDialog(api: widget.api, initial: transaction!),
            )
          : transaction;
      if (outcome == null) {
        final reverted = await widget.api.cancel(transaction.id);
        resultMessage = reverted.message;
      } else {
        resultMessage = outcome.confirmed
            ? '«${profile.name}». ${outcome.message}'
            : outcome.message;
      }
    } catch (error) {
      resultMessage = errorText(error);
      if (transaction != null) {
        try {
          await widget.api.cancel(transaction.id);
        } catch (_) {
          resultMessage =
              '$resultMessage Автовозврат выполняется Windows-модулем; проверьте состояние экрана.';
        }
      }
    } finally {
      try {
        final snapshot = await widget.api.snapshot();
        if (mounted) setState(() => system = snapshot);
        await widget.store.write(AppSettings.capture(saved, snapshot));
      } catch (error) {
        resultMessage =
            '${resultMessage ?? ''}\nНе удалось обновить состояние или сохранить настройки: ${errorText(error)}';
      }
      if (mounted) setState(() => busy = false);
      if (resultMessage != null) notify(resultMessage);
    }
  }

  bool canApply(EnergyProfile profile) =>
      profile.supported(system!) &&
      (!profile.windowsSaver || system!.saverAvailable);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: system == null
          ? loadingOrError()
          : LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 940;
                return SingleChildScrollView(
                  padding: EdgeInsets.all(compact ? 24 : 36),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          header(),
                          const SizedBox(height: 24),
                          currentStatus(),
                          const SizedBox(height: 14),
                          batteryPanel(),
                          const SizedBox(height: 28),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (int i = 0; i < 3; i++) ...[
                                if (i > 0) const SizedBox(width: 14),
                                Expanded(child: profileCard(i, compact)),
                              ],
                            ],
                          ),
                          const SizedBox(height: 22),
                          editor(compact),
                          const SizedBox(height: 16),
                          const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.verified_user_outlined,
                                size: 16,
                                color: muted,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'После переключения подтвердите изображение за 15 секунд. Без подтверждения вернутся прежние настройки.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: muted,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    ),
  );

  Widget loadingOrError() => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: failure == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 40,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Не удалось загрузить настройки',
                    style: TextStyle(fontSize: 24),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(failure!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  SelectableText(
                    'Файл настроек: ${widget.store.file.path}',
                    style: const TextStyle(color: muted),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: busy ? null : initialize,
                    child: const Text('Повторить'),
                  ),
                ],
              ),
      ),
    ),
  );

  Widget header() => Row(
    children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(
          Icons.power_settings_new_rounded,
          color: accent,
          size: 30,
        ),
      ),
      const SizedBox(width: 16),
      const Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Энергопрофили',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.8,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Настройте один раз. Переключайтесь по ситуации.',
              style: TextStyle(color: muted, fontSize: 13),
            ),
          ],
        ),
      ),
      IconButton(
        tooltip: 'Обновить мониторы и текущие параметры',
        onPressed: busy ? null : refresh,
        icon: const Icon(Icons.refresh_rounded, color: muted),
      ),
    ],
  );

  Widget currentStatus() {
    final primary =
        system!.monitors.where((item) => item.primary).firstOrNull ??
        system!.monitors.firstOrNull;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2B3744)),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            'СЕЙЧАС',
            style: TextStyle(
              color: accent,
              fontSize: 10,
              letterSpacing: 1.6,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (primary != null)
            Text(
              '${primary.current.resolution}  /  ${primary.current.hz} Гц',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          Text(
            'Windows: ${system!.powerName}',
            style: const TextStyle(color: muted, fontSize: 13),
          ),
          Text(
            'Экономия Windows: ${system!.energySaverStatus < 0
                ? 'нет данных'
                : system!.saverActive
                ? 'включена'
                : 'выключена'}',
            style: TextStyle(
              color: system!.saverActive ? accent : muted,
              fontSize: 13,
            ),
          ),
          Text(
            system!.onBattery
                ? 'От батареи${system!.batteryPercent <= 100 ? ' · ${system!.batteryPercent}%' : ''}'
                : 'От сети',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget batteryPanel() {
    final battery = system!.battery;
    Widget metric(String title, String value) => SizedBox(
      width: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              fontSize: 23,
              color: accent,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
    final minutes = battery?.estimatedMinutes;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 18,
            children: [
              metric(
                'Текущий расход',
                battery?.dischargeWatts == null
                    ? '—'
                    : '${battery!.dischargeWatts!.toStringAsFixed(1)} Вт',
              ),
              metric(
                'Осталось энергии',
                battery?.remainingWh == null
                    ? '—'
                    : '${battery!.remainingWh!.toStringAsFixed(1)} Вт·ч',
              ),
              metric(
                'Примерно осталось',
                minutes == null
                    ? '—'
                    : '${minutes ~/ 60} ч ${minutes % 60} мин',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            !system!.onBattery
                ? 'От сети: оценка автономности появится при разряде батареи.'
                : 'Оценка по текущему расходу, а не гарантированное время работы. Обновляется каждые 5 секунд.',
            style: const TextStyle(color: muted, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget profileCard(int index, bool compact) {
    final profile = drafts[index];
    final chosen = selected == index;
    final color = profileColors[index];
    final dirty = profile != saved[index];
    return Container(
      decoration: BoxDecoration(
        color: chosen ? color.withValues(alpha: 0.07) : surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: chosen ? color : const Color(0xFF2B3744),
          width: chosen ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: busy ? null : () => setState(() => selected = index),
            child: Padding(
              padding: EdgeInsets.all(compact ? 15 : 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(profileIcons[index], size: 28, color: color),
                      const Spacer(),
                      if (dirty)
                        const Tooltip(
                          message: 'Есть несохранённые изменения',
                          child: Icon(
                            Icons.circle,
                            size: 7,
                            color: Colors.orangeAccent,
                          ),
                        )
                      else if (profile.matches(system!))
                        const Tooltip(
                          message: 'Совпадает с текущими параметрами',
                          child: Icon(
                            Icons.check_circle_outline,
                            size: 18,
                            color: accent,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 17),
                  Text(
                    profile.name,
                    style: TextStyle(
                      fontSize: compact ? 15 : 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 7),
                  SizedBox(
                    height: 35,
                    child: Text(
                      profileDescriptions[index],
                      style: const TextStyle(
                        color: muted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    profile.mode.resolution,
                    style: TextStyle(
                      fontSize: compact ? 19 : 23,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${profile.mode.hz} Гц',
                    style: TextStyle(color: color, fontSize: 14),
                  ),
                  if (profile.brightness != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        'Яркость ${profile.brightness}%',
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 15 : 20,
              0,
              compact ? 15 : 20,
              18,
            ),
            child: OutlinedButton(
              onPressed: busy || !canApply(profile)
                  ? null
                  : () => applyProfile(index),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                foregroundColor: color,
                side: BorderSide(color: color.withValues(alpha: 0.4)),
              ),
              child: const Text('Применить'),
            ),
          ),
        ],
      ),
    );
  }

  Widget editor(bool compact) {
    final profile = drafts[selected];
    final monitor = system!.monitor(profile.monitorId);
    final supported = profile.supported(system!);
    final dirty = profile != saved[selected];
    final monitors = system!.monitors;
    final resolutions = monitor?.resolutions ?? <String>[];
    if (!resolutions.contains(profile.mode.resolution)) {
      resolutions.insert(0, profile.mode.resolution);
    }
    final rates =
        monitor?.atResolution(profile.mode.resolution) ?? <DisplayMode>[];
    if (!rates.contains(profile.mode)) rates.add(profile.mode);
    return Container(
      padding: EdgeInsets.all(compact ? 20 : 24),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2B3744)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 20,
                color: profileColors[selected],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Настройки · ${profile.name}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                dirty ? 'Не сохранено' : 'Сохранено',
                style: TextStyle(
                  fontSize: 12,
                  color: dirty ? Colors.orangeAccent : muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          DropdownButtonFormField<String>(
            key: ValueKey('monitor-${profile.id}-${profile.monitorId}'),
            initialValue: profile.monitorId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Монитор'),
            items: [
              if (monitor == null)
                DropdownMenuItem(
                  value: profile.monitorId,
                  child: Text('Недоступен · ${profile.monitorId}'),
                ),
              for (final item in monitors)
                DropdownMenuItem(
                  value: item.id,
                  child: Text(item.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: busy
                ? null
                : (id) {
                    final next = system!.monitor(id!)!;
                    edit(
                      profile.copyWith(
                        monitorId: id,
                        mode: next.modes.contains(profile.mode)
                            ? profile.mode
                            : next.current,
                        brightness:
                            profile.brightness == null ||
                                next.brightness == null
                            ? null
                            : next.nearestBrightness(profile.brightness!),
                        clearBrightness: next.brightness == null,
                      ),
                    );
                  },
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  key: ValueKey(
                    'resolution-${profile.id}-${profile.monitorId}-${profile.mode.resolution}',
                  ),
                  initialValue: profile.mode.resolution,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Разрешение'),
                  items: [
                    for (final resolution in resolutions)
                      DropdownMenuItem(
                        value: resolution,
                        child: Text(resolution),
                      ),
                  ],
                  onChanged: busy || monitor == null
                      ? null
                      : (resolution) {
                          final modes = monitor.atResolution(resolution!);
                          final next =
                              modes
                                  .where((mode) => mode.hz == profile.mode.hz)
                                  .firstOrNull ??
                              modes.first;
                          edit(profile.copyWith(mode: next));
                        },
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<int>(
                  key: ValueKey(
                    'hz-${profile.id}-${profile.monitorId}-${profile.mode.resolution}-${profile.mode.hz}',
                  ),
                  initialValue: profile.mode.hz,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Частота обновления',
                  ),
                  items: [
                    for (final mode in rates)
                      DropdownMenuItem(
                        value: mode.hz,
                        child: Text('${mode.hz} Гц'),
                      ),
                  ],
                  onChanged: busy || monitor == null
                      ? null
                      : (hz) => edit(
                          profile.copyWith(
                            mode: DisplayMode(
                              profile.mode.width,
                              profile.mode.height,
                              hz!,
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (!supported)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Сохранённый режим сейчас недоступен. Выберите подключённый монитор и поддерживаемые параметры.',
                style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.brightness_6_outlined, size: 20, color: muted),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Яркость экрана',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
              Text(
                profile.brightness == null
                    ? 'Не менять'
                    : '${profile.brightness}%',
                style: const TextStyle(color: accent),
              ),
              const SizedBox(width: 12),
              Switch(
                value: profile.brightness != null,
                onChanged:
                    busy ||
                        (monitor?.brightness == null &&
                            profile.brightness == null)
                    ? null
                    : (enabled) => edit(
                        profile.copyWith(
                          brightness: monitor?.brightness == null
                              ? null
                              : monitor!.nearestBrightness(monitor.brightness!),
                          clearBrightness: !enabled,
                        ),
                      ),
              ),
            ],
          ),
          Slider(
            value: (profile.brightness ?? monitor?.brightness ?? 50)
                .clamp(0, 100)
                .toDouble(),
            min: 0,
            max: 100,
            divisions: 100,
            label: '${profile.brightness ?? monitor?.brightness ?? 50}%',
            onChanged:
                busy ||
                    monitor?.brightness == null ||
                    profile.brightness == null
                ? null
                : (value) => edit(
                    profile.copyWith(
                      brightness: monitor!.nearestBrightness(value.round()),
                    ),
                  ),
          ),
          Text(
            monitor?.brightness == null
                ? 'Этот монитор не предоставляет системное управление яркостью.'
                : 'Значение сохраняется в профиле и применяется вместе с разрешением и частотой.',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          CheckboxListTile(
            value: profile.windowsSaver,
            onChanged: busy
                ? null
                : (value) => edit(profile.copyWith(windowsSaver: value!)),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text(
              'Энергосбережение Windows',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                system!.powerDescription,
                style: const TextStyle(color: muted, fontSize: 12, height: 1.5),
              ),
            ),
          ),
          if (!system!.saverAvailable)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Windows не предоставляет доступный режим энергосбережения. Снимите галочку, чтобы менять только параметры монитора.',
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          TextButton.icon(
            onPressed: busy
                ? null
                : () async {
                    try {
                      await widget.api.openPowerSettings();
                    } catch (error) {
                      notify(errorText(error));
                    }
                  },
            icon: const Icon(Icons.open_in_new, size: 15),
            label: const Text('Открыть энергосбережение Windows'),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: busy || !canApply(profile)
                    ? null
                    : () => applyProfile(selected),
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: const Text('Применить профиль'),
              ),
              OutlinedButton.icon(
                onPressed: busy || !dirty ? null : save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Сохранить профиль'),
              ),
              TextButton(
                onPressed: busy || !dirty ? null : () => edit(saved[selected]),
                child: const Text('Отменить правки'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ConfirmationDialog extends StatefulWidget {
  const ConfirmationDialog({
    super.key,
    required this.api,
    required this.initial,
  });
  final WindowsApi api;
  final TransactionStatus initial;
  @override
  State<ConfirmationDialog> createState() => _ConfirmationDialogState();
}

class _ConfirmationDialogState extends State<ConfirmationDialog> {
  late TransactionStatus status;
  Timer? timer;
  bool working = false, closed = false;
  String? error;
  @override
  void initState() {
    super.initState();
    status = widget.initial;
    timer = Timer.periodic(const Duration(milliseconds: 400), (_) => poll());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void acceptStatus(TransactionStatus next) {
    if (!mounted || closed) return;
    if (!next.pending) {
      closed = true;
      timer?.cancel();
      Navigator.of(context).pop(next);
    } else {
      setState(() => status = next);
    }
  }

  Future<void> poll() async {
    if (working || closed) return;
    working = true;
    try {
      acceptStatus(await widget.api.status());
    } catch (failure) {
      if (mounted) setState(() => error = errorText(failure));
    } finally {
      working = false;
    }
  }

  Future<void> act(bool confirm) async {
    if (working || closed) return;
    setState(() => working = true);
    try {
      acceptStatus(
        confirm
            ? await widget.api.confirm(status.id)
            : await widget.api.cancel(status.id),
      );
    } catch (failure) {
      if (mounted) setState(() => error = errorText(failure));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      icon: const Icon(Icons.monitor_rounded, color: accent, size: 34),
      title: const Text('Сохранить эти настройки?'),
      content: SizedBox(
        width: 410,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Если изображение видно и всё работает, подтвердите новый режим.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Text(
              '${status.seconds}',
              style: const TextStyle(
                fontSize: 48,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Text(
              'секунд до возврата прежних настроек',
              style: TextStyle(fontSize: 12, color: muted),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: working ? null : () => act(false),
          child: const Text('Вернуть как было'),
        ),
        FilledButton(
          onPressed: working ? null : () => act(true),
          child: const Text('Подтвердить'),
        ),
      ],
    ),
  );
}
