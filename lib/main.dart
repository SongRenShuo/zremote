import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/app_localizations.dart';
import 'models/device_label.dart';
import 'services/biometric.dart';
import 'services/log_buffer.dart';
import 'services/startup_guard.dart';
import 'state/appearance.dart';
import 'state/locale.dart';
import 'state/theme_mode.dart';
import 'state/session_pool.dart';
import 'theme.dart';
import 'state/app_lifecycle.dart';
import 'ui/app_shell.dart';
import 'ui/bevel_card.dart';
import 'ui/showcase_bits.dart';

/// 启动顺序铁律（fix/hos-startup，鸿蒙白屏根因修复）：
/// runApp 之前禁止 await 任何平台通道调用——HarmonyOS 上 stock 版
/// shared_preferences / flutter_secure_storage / flutter_local_notifications
/// 没有 ohos 平台实现，通道调用会永久悬挂，main() 一旦先 await 它们，
/// runApp 永不执行 → 首屏全白（Android/iOS 不受影响，但顺序本身是脆弱点）。
/// 首帧只做纯 Dart 侧装配；插件初始化走 [StartupGuard.warmUp] 后台异步，
/// 完成后由各 Riverpod notifier 的 _load() 刷新状态（state/locale.dart 等
/// 均支持无 initial 时异步读盘回落，Android/iOS 的启动读盘语义保持生效，
/// 只是首帧不再被读盘阻塞）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // P3-2：诊断日志环形缓冲装配（debugPrint 流捕获 + 原样输出）。
  LogBuffer.installDebugPrintCapture();
  runApp(const ProviderScope(child: ZRemoteApp()));
  // 对照实验结论（2026-11-16，ohos-x64 模拟器）：先 runApp 后台异步初始化
  // 首屏正常渲染（见 fix/hos-startup 提交记录）；原「先 await 读盘再 runApp」
  // 则白屏且无任何 Dart 异常。
  StartupGuard.warmUp();
}

class ZRemoteApp extends ConsumerWidget {
  const ZRemoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setting = ref.watch(localeSettingProvider);
    final themeSetting = ref.watch(themeModeSettingProvider);
    final appearance = ref.watch(appearanceProvider);
    final relockSeconds = ref.watch(relockDelayProvider);
    return MaterialApp(
      title: 'ZRemoteX',
      debugShowCheckedModeBanner: false,
      theme: ZT.theme(Brightness.light),
      // P3-3：oled 档 = dark 亮度 + 纯黑调色板。
      darkTheme: ZT.theme(
        Brightness.dark,
        palette: isOledSetting(themeSetting) ? ZT.oled : null,
      ),
      themeMode: resolveThemeMode(themeSetting),
      locale: setting == kLocaleSystem ? null : Locale(setting),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const LifecycleWatcher(child: AppShell()),
      builder: (context, child) {
        // P3-3：应用内字号缩放（与系统无障碍系数相乘，14px 基准取样）。
        final media = MediaQuery.maybeOf(context);
        final systemFactor = (media?.textScaler ?? TextScaler.noScaling)
            .scale(14) / 14;
        final factor = systemFactor * appearance.fontScale.factor;
        return MediaQuery(
          data: (media ?? const MediaQueryData())
              .copyWith(textScaler: TextScaler.linear(factor)),
          child: BiometricGate(
            // P3-8：自动锁定延时可配（立即/10s/60s/5min）。
            relockAfter: Duration(seconds: relockSeconds),
            child: child!,
          ),
        );
      },
    );
  }
}

class BiometricGate extends ConsumerStatefulWidget {
  const BiometricGate({
    super.key,
    required this.child,
    this.relockAfter = const Duration(seconds: 10),
    this.authenticate = _defaultAuthenticate,
    this.haloAnimated = true,
  });

  final Widget child;

  final Duration relockAfter;

  final Future<bool> Function(String reason) authenticate;

  final bool haloAnimated;

  static Future<bool> _defaultAuthenticate(String reason) =>
      BiometricService.instance.authenticate(reason);

  @override
  ConsumerState<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends ConsumerState<BiometricGate>
    with WidgetsBindingObserver {
  bool _authed = false;
  bool _authenticating = false;
  bool _startupPrompted = false;
  DateTime? _leftAt;
  bool _authCovered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startupPrompted = true;
      if (ref.read(biometricProvider)) _unlock();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      if (_authenticating) {
        _authCovered = true;
      } else {
        _leftAt ??= DateTime.now();
      }
    } else if (state == AppLifecycleState.resumed) {
      final covered = _authCovered;
      _authCovered = false;
      final leftAt = _leftAt;
      _leftAt = null;
      if (!ref.read(biometricProvider)) return;
      if (!_startupPrompted) return;
      if (covered) {
        return;
      }
      final lastSuccess = BiometricService.instance.lastSuccessAt;
      if (lastSuccess != null &&
          DateTime.now().difference(lastSuccess) < widget.relockAfter) {
        return;
      }
      final away = leftAt == null
          ? widget
                .relockAfter
          : DateTime.now().difference(leftAt);
      if (away < widget.relockAfter && _authed) return;
      _relockAndPrompt();
    }
  }

  void _relockAndPrompt() {
    if (!_authed) {
      _unlock();
      return;
    }
    setState(() => _authed = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _unlock();
    });
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    _authenticating = true;
    try {
      final reason = (AppLocalizations.of(context) ?? l10nZh).unlockReason;
      final ok = await widget.authenticate(reason);
      if (mounted && ok) setState(() => _authed = true);
    } on BiometricUnavailableException {
      if (mounted) {
        await ref.read(biometricProvider.notifier).set(false);
        if (mounted) setState(() => _authed = true);
      }
    } catch (_) {
    } finally {
      _authenticating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(biometricProvider);
    final locked = enabled && !_authed;
    final l10n = AppLocalizations.of(context) ?? l10nZh;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (locked)
          Positioned.fill(
            child: BlockSemantics(
              blocking: true,
              child: Scaffold(
                backgroundColor: context.zt.bg,
                body: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, viewport) => SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: viewport.maxHeight,
                        ),
                        child: Align(
                          alignment: const Alignment(0, -0.55),
                          child: SizedBox(
                            width: double.infinity,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _SenseHalo(animated: widget.haloAnimated),
                                  const SizedBox(height: 24),
                                  Text(
                                    l10n.lockTitle,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.4,
                                      color: context.zt.textHi,
                                    ),
                                  ),
                                  const SizedBox(height: 30),
                                  BevelCard(
                                    onTap: _unlock,
                                    margin: EdgeInsets.zero,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 14,
                                    ),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: 36,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              color: context.zt.accentSubtle,
                                            ),
                                            child: Icon(
                                              Icons.fingerprint,
                                              size: 26,
                                              color: context.zt.accent,
                                            ),
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  l10n.lockActionPrimary,
                                                  style: TextStyle(
                                                    fontSize: 15,
                                                    fontWeight:
                                                        FontWeight.w600,
                                                    color: context.zt.textHi,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  l10n.lockActionFallback,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: context.zt.textLo,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Icon(
                                            Icons.chevron_right,
                                            color: context.zt.textLo,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 36),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.shield_outlined,
                                        size: 12,
                                        color: context.zt.textTertiary,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        l10n.lockFooter,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: context.zt.textTertiary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SenseHalo extends StatefulWidget {
  const _SenseHalo({required this.animated});

  final bool animated;

  @override
  State<_SenseHalo> createState() => _SenseHaloState();
}

class _SenseHaloState extends State<_SenseHalo>
    with SingleTickerProviderStateMixin {
  AnimationController? _breath;

  @override
  void initState() {
    super.initState();
    if (widget.animated) {
      _breath = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2400),
      )..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    final glow = IgnorePointer(
      child: Container(
        width: 150,
        height: 150,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              zt.accent.withValues(alpha: 0.13),
              zt.accent.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );
    final ring = CustomPaint(
      size: const Size(130, 130),
      painter: ZrDashedBorderPainter(
        color: zt.accent.withValues(alpha: 0.4),
        radius: 65,
        strokeWidth: 1.5,
        dash: 6,
        gap: 5,
      ),
    );
    final iconBox = Container(
      width: 68,
      height: 68,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: zt.surfaceHi,
        border: Border.all(color: zt.hairline, width: 0.8),
      ),
      child: Center(
        child: Image.asset('assets/brand/mark.png', width: 42, height: 42),
      ),
    );
    final controller = _breath;
    return SizedBox(
      width: 150,
      height: 150,
      child: Stack(
        alignment: Alignment.center,
        children: [
          glow,
          if (controller == null)
            ring
          else
            ScaleTransition(
              scale: Tween<double>(begin: 1.0, end: 1.06).animate(
                CurvedAnimation(
                  parent: controller,
                  curve: Curves.easeInOut,
                ),
              ),
              child: ring,
            ),
          iconBox,
        ],
      ),
    );
  }
}
