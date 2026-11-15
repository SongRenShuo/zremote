import 'dart:async';
import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../services/account_vault.dart';
import '../services/approval_extractor.dart';
import '../services/auth_popup_policy.dart';
import '../services/event_observer.dart';
import '../services/git_overview.dart';
import '../services/link_builder.dart';
import '../services/notifier.dart';
import '../services/rpc_bridge.dart';
import '../services/rpc_codec.dart';
import '../services/rpc_dispatch.dart';
import '../services/resume_health.dart';
import '../services/service_probe.dart';
import '../services/session_jump.dart';
import '../services/task_actions.dart';
import '../services/web_theme.dart';
import '../services/webview_profile.dart';
import '../services/zai_auth_client.dart';
import '../state/active_session.dart';
import '../state/accounts.dart';
import '../state/app_lifecycle.dart';
import '../state/approval_center.dart';
import '../state/automation.dart';
import '../state/claim_config.dart';
import '../state/claim_entry.dart';
import '../state/claim_scheduler_hub.dart';
import '../state/event_feed.dart';
import '../state/notification_prefs.dart';
import '../state/resume_reload.dart';
import '../state/service_readiness.dart';
import '../state/session_index.dart';
import '../state/session_pool.dart';
import '../state/session_status.dart';
import '../state/toolbox_nav.dart';
import '../theme.dart';
import '../models/device_label.dart';
import 'account_vault_page.dart';
import 'assets_page.dart';
import 'automation_page.dart';
import 'claim_page.dart';
import 'desktop_settings_page.dart';
import 'diagnostics_page.dart';
import 'haptics.dart';
import 'login_web_page.dart';
import 'model_settings_page.dart';
import 'motion.dart';
import 'quota_page.dart';
import 'rewards_page.dart';
import 'session_panel.dart';
import 'sheet_shell.dart';
import 'status_led.dart';
import 'toolbox_sheet.dart';
import 'unread_badge.dart';
import 'usage_page.dart';
import 'webview_popup.dart';

class SessionView extends ConsumerStatefulWidget {
  final RemoteDevice device;

  const SessionView({super.key, required this.device});

  @override
  ConsumerState<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends ConsumerState<SessionView> {
  InAppWebViewController? _controller;
  bool _loading = true;
  bool _errorShown = false;
  DateTime _lastAutoReload = DateTime.fromMillisecondsSinceEpoch(0);

  SessionStatusNotifier? _statusNotifier;
  EventFeedNotifier? _feedNotifier;
  SessionIndexNotifier? _sessionIndexNotifier;
  ActiveSessionNotifier? _activeSessionNotifier;
  AutomationNotifier? _automationNotifier;
  ClaimEntryNotifier? _claimEntryNotifier;
  ClaimServiceNotifier? _claimServiceNotifier;
  ServiceReadinessNotifier? _readinessNotifier;
  ApprovalCenterNotifier? _approvalCenterNotifier;

  bool _claimEntryProbed = false;

  /// 宿主当前工作区缓存（sessionIndex 的 workspacePath 实测全 null 时的回退）。
  String? _hostWorkspacePath;

  int _readinessEpoch = 0;

  RpcBridge? _rpcBridge;

  LoopbackDispatchServer? _dispatchServer;
  int? _dispatchPort;

  final ResumeWatch _resumeWatch = ResumeWatch();
  bool _rendererGone = false;
  DateTime _lastWsActivity = DateTime.now();
  Timer? _resumeGrace;

  int _resumeProbeSeq = 0;
  bool _resumeProbeInFlight = false;

  final StateDiffer _stateDiffer = StateDiffer();

  String? _activeSessionId;

  bool _probeArmed = true;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool? _appliedWebDark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _statusNotifier ??= ref.read(sessionStatusProvider.notifier);
    _feedNotifier ??= ref.read(eventFeedProvider.notifier);
    _sessionIndexNotifier ??= ref.read(sessionIndexProvider.notifier);
    _activeSessionNotifier ??= ref.read(activeSessionProvider.notifier);
    _automationNotifier ??= ref.read(automationProvider.notifier);
    _claimEntryNotifier ??= ref.read(claimEntryProvider.notifier);
    _claimServiceNotifier ??= ref.read(claimServiceProvider.notifier);
    _readinessNotifier ??= ref.read(serviceReadinessProvider.notifier);
    _approvalCenterNotifier ??= ref.read(approvalCenterProvider.notifier);
    _startDispatch();
  }

  void _startDispatch() {
    if (_dispatchServer != null) return;
    final server = LoopbackDispatchServer();
    _dispatchServer = server;
    server
        .start()
        .then((_) {
          if (!mounted) {
            server.dispose();
            return;
          }
          setState(() => _dispatchPort = server.port);
        })
        .catchError((Object e) {
          debugPrint('[zr-diag] dispatch server bind failed: $e');
        });
  }

  @override
  void didUpdateWidget(covariant SessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldDev = oldWidget.device;
    final newDev = widget.device;
    if (oldDev.id == newDev.id &&
        (oldDev.baseUrl != newDev.baseUrl ||
            !mapEquals(oldDev.params, newDev.params))) {
      _manualReload();
    }
  }

  void _report(SessionStatus status) =>
      _statusNotifier?.report(widget.device.id, status);

  void _reportServiceReadiness(ServiceReadiness readiness) {
    if (!mounted) return;
    _readinessNotifier?.report(widget.device.id, readiness);
  }

  void _onWsEvent(String body) {
    if (!mounted) return;
    _lastWsActivity = DateTime.now();
    try {
      final event = jsonDecode(body);
      if (event is Map<String, dynamic>) {
        final status = RelayLedPolicy.onWsEvent(event);
        if (event['s'] == 'closed') {
          debugPrint('[zr-resume] ws closed r=${event['r']} -> $status');
        }
        if (status != null) _report(status);
      }
    } catch (_) {}
  }

  void _onAppResume() {
    final now = DateTime.now();
    final status = ref.read(sessionStatusProvider)[widget.device.id];
    final wsIdle = now.difference(_lastWsActivity);
    final signal = _resumeWatch.onResumed(
      now: now,
      rendererGone: _rendererGone,
      live: status == SessionStatus.live,
      sinceWsActivity: wsIdle,
    );
    debugPrint(
      '[zr-resume] check rendererGone=$_rendererGone status=$status '
      'wsIdle=${wsIdle.inSeconds}s -> $signal',
    );
    switch (signal) {
      case ResumeSignal.none:
      case ResumeSignal.keepGrace:
        break;
      case ResumeSignal.verifyWritePath:
        unawaited(_verifyWritePath());
      case ResumeSignal.reloadNow:
        _rendererGone = false;
        _manualReload('resume-renderer-gone');
      case ResumeSignal.armGrace:
        unawaited(_verifyWritePath());
        _resumeGrace?.cancel();
        _resumeGrace = Timer(ResumeHealthPolicy.grace, () {
          _resumeGrace = null;
          _resumeWatch.clearGrace();
          if (!mounted) return;
          final nowStatus = ref.read(sessionStatusProvider)[widget.device.id];
          final healthy =
              nowStatus == SessionStatus.live &&
              DateTime.now().difference(_lastWsActivity) <
                  ResumeHealthPolicy.quietThreshold;
          debugPrint(
            '[zr-resume] grace end status=$nowStatus '
            'wsIdle=${DateTime.now().difference(_lastWsActivity).inSeconds}s '
            'healthy=$healthy',
          );
          if (!healthy) {
            _manualReload('resume-grace-expired');
          } else if (!_resumeProbeInFlight) {
            unawaited(_verifyWritePath());
          }
        });
    }
  }

  Future<void> _verifyWritePath() async {
    final bridge = _rpcBridge;
    if (bridge == null || !mounted || _resumeProbeInFlight) return;
    final seq = ++_resumeProbeSeq;
    _resumeProbeInFlight = true;
    debugPrint('[zr-resume] write-path probe arm seq=$seq');
    try {
      await bridge.call(
        'off-peak-task',
        'getCodingPlanSupport',
        timeout: const Duration(seconds: 25),
      );
      debugPrint('[zr-resume] write-path probe ok');
    } on RpcRemoteException catch (e) {
      debugPrint('[zr-resume] write-path probe rsp: ${e.message}');
      if (e.message.contains('no-services')) {
        _reloadOnWriteDead(seq);
      }
    } catch (e) {
      debugPrint('[zr-resume] write-path probe dead: $e');
      _reloadOnWriteDead(seq);
    } finally {
      _resumeProbeInFlight = false;
    }
  }

  void _reloadOnWriteDead(int seq) {
    if (!mounted || seq != _resumeProbeSeq || _loading) return;
    _manualReload('resume-write-dead');
    ref.read(resumeReloadEpochProvider.notifier).bump();
  }

  void _goHome() => ref
      .read(activeTabProvider.notifier)
      .set(ref.read(deviceListProvider).length);

  void _onBridgeMessage(String body) {
    if (!mounted) return;
    _lastWsActivity = DateTime.now();
    dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      root = null;
    }
    final frameLed = RelayLedPolicy.onFrameRoot(root);
    if (frameLed != null) _report(frameLed);
    if (frameLed == SessionStatus.live && _probeArmed) {
      _probeArmed = false;
      unawaited(_runServiceProbe());
    }

    final activeSession = ActiveSessionExtractor.parseRoot(root);
    if (activeSession != null) {
      _activeSessionId = activeSession;
      _activeSessionNotifier?.report(widget.device.id, activeSession);
    }
    final states = SessionStateExtractor.parseRoot(root);
    final removed = [
      ...SessionStateExtractor.parseRemovedRoot(root),
      ...TaskIndexExtractor.parseRemovedRoot(root),
      ...TaskIndexExtractor.parseArchivedRoot(root),
    ];
    _sessionIndexNotifier?.upsertAll(widget.device.id, states);
    _sessionIndexNotifier?.removeSessions(widget.device.id, removed);
    final snapshotTasks = TaskIndexExtractor.parseSnapshotRoot(root);
    if (snapshotTasks != null) {
      _sessionIndexNotifier?.replaceTasks(widget.device.id, snapshotTasks);
    } else {
      final taskEntries = TaskIndexExtractor.parseRoot(root);
      _sessionIndexNotifier?.upsertTasks(widget.device.id, taskEntries);
    }
    final resultTasks = TaskIndexExtractor.parseResultTasksRoot(root);
    if (resultTasks != null && resultTasks.isNotEmpty) {
      if (TaskIndexExtractor.isBootstrapResult(root)) {
        _sessionIndexNotifier?.replaceTasks(
          widget.device.id,
          resultTasks,
          preservePinned: true,
        );
      } else {
        _sessionIndexNotifier?.upsertTasks(widget.device.id, resultTasks);
      }
    }

    final codingPlan = CodingPlanSignalExtractor.parseRoot(root);
    if (codingPlan != null) {
      _automationNotifier?.reportSubscribed(widget.device.id, true);
    }
    final automationInputs = root != null
        ? <dynamic>[root]
        : body.startsWith('{')
        ? RpcCodec.parseConcatenatedJsonText(body)
        : const <dynamic>[];
    final offPeakFeed = AutomationFeed.offPeakOf(automationInputs);
    if (offPeakFeed.snapshot) {
      _automationNotifier?.replaceOffPeak(widget.device.id, offPeakFeed.tasks);
    } else if (offPeakFeed.tasks.length == 1) {
      _automationNotifier?.upsertOffPeak(
        widget.device.id,
        offPeakFeed.tasks.single,
      );
    }
    final autosFeed = AutomationFeed.automationsOf(automationInputs);
    if (autosFeed.snapshot) {
      _automationNotifier?.replaceAutomations(
        widget.device.id,
        autosFeed.automations,
      );
    } else if (autosFeed.automations.length == 1) {
      _automationNotifier?.upsertAutomation(
        widget.device.id,
        autosFeed.automations.single,
      );
    }
    final projects = RecentProjectsExtractor.parseRoot(root);
    if (projects != null) {
      _automationNotifier?.reportProjects(widget.device.id, projects);
    }

    final events = <ObservedEvent>[
      ...EventParser.parseRoot(root),
      ..._stateDiffer.apply(states, removed: removed),
    ];
    // P1-4：审批待办被动喂流（requestId/选项集供通知动作按钮回执）。
    final approvalSignals = ApprovalExtractor.parseRoot(root);
    if (approvalSignals.isNotEmpty) {
      _approvalCenterNotifier?.ingest(widget.device.id, approvalSignals);
    }
    if (events.isEmpty) return;
    final devices = ref.read(deviceListProvider);
    final active = ref.read(activeTabProvider);
    final visibleId = active < devices.length ? devices[active].id : null;
    final appForeground =
        ref.read(appLifecycleProvider) == AppLifecycleState.resumed;
    final prefs = ref.read(notificationPrefsProvider);
    for (final event in events) {
      if (event.type == 'resolved') {
        final taskId = event.taskId;
        if (taskId != null) {
          NotifierService.instance.cancelPending(widget.device, taskId);
          _approvalCenterNotifier?.ingest(widget.device.id, [
            ApprovalSignal.resolved(taskId),
          ]);
        }
        _feedNotifier?.ingest(widget.device.id, event);
        continue;
      }
      if (!prefs.enabled(event.type)) continue;
      final notify = NotificationGate.shouldNotify(
        appForeground: appForeground,
        visibleDeviceId: visibleId,
        eventDeviceId: widget.device.id,
        activeSessionId: _activeSessionId,
        eventSessionId: event.taskId,
      );
      if (!notify) continue;
      _feedNotifier?.ingest(widget.device.id, event);
      NotifierService.instance.notifyFrom(
        widget.device,
        event,
        l10n: AppLocalizations.of(context),
      );
    }
  }

  Future<void> _runServiceProbe() async {
    final bridge = _rpcBridge;
    if (bridge == null) return;
    final epoch = _readinessEpoch;
    try {
      final report = await ServiceProbe.run(bridge);
      if (widget.device.kind != DeviceKind.v2) return;
      if (!mounted || epoch != _readinessEpoch) return;
      final dump = report['dump'];
      if (dump is Map && dump['ok'] == true) {
        _reportServiceReadiness(ServiceReadiness.ready);
      } else if (dump is Map &&
          '${dump['error'] ?? ''}'.contains('no-services')) {
        _reportServiceReadiness(ServiceReadiness.unavailable);
      }
    } catch (_) {}
  }

  void _onViewStateSync(String body) {
    if (!mounted) return;
    final r = MobileViewStateSync.parse(body);
    if (!r.valid) return;
    _activeSessionId = r.taskId;
    _activeSessionNotifier?.report(widget.device.id, r.taskId);
  }

  URLRequest _freshRequest() =>
      URLRequest(url: WebUri(LinkBuilder.buildUrl(widget.device).toString()));

  /// v4/V2 页面登录用 `window.open` 弹窗完成 OAuth（主页面轮询票据）。
  /// 接管新窗口：带 windowId 时弹窗 WebView 会消费 transport，使
  /// opener 拿到真实 window 句柄；真实 URL 弹窗（target=_blank）直接
  /// 加载该 URL。未接管返回 false，行为退化为丢弃窗口。
  bool _openAuthPopup(CreateWindowAction action) {
    if (!mounted) return false;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => AuthPopupPage(
            device: widget.device,
            windowId: action.windowId,
            initialRequest: AuthPopupPolicy.initialRequestFor(action),
          ),
        ),
      ),
    );
    return true;
  }

  // ---- 账号与登录（V2 P0 接线）----

  Future<String?> _evaluateOnPage(String script) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      return await controller.evaluateJavascript(source: script) as String?;
    } catch (e) {
      debugPrint('[zr-vault] evaluate failed: $e');
      return null;
    }
  }

  /// 回读当前设备 zcode.z.ai origin 的凭据仓（保全/保存当前登录共用）。
  Future<Map<String, String>> _readCurrentCredentials() async {
    final raw = await _evaluateOnPage(AccountVault.credentialReadScript());
    return AccountVault.parseReadResult(raw);
  }

  /// 账号注入 + 刷新（账号库页「应用」回调通道）。
  Future<bool> _applyAccountToWebView(Account account) async {
    final script = AccountVault.applyToDevice(account, widget.device);
    if (script.isNotEmpty) {
      await _evaluateOnPage(script);
    }
    await _manualReload('vault-apply');
    return true;
  }

  Future<void> _openLogin() async {
    if (!mounted) return;
    final outcome = await Navigator.of(context).push<LoginWebOutcome>(
      MaterialPageRoute<LoginWebOutcome>(
        fullscreenDialog: true,
        builder: (_) => LoginWebPage(device: widget.device),
      ),
    );
    if (!mounted) return;
    unawaited(
      ref.read(accountsProvider.notifier).reload().catchError((Object e) {
        debugPrint('[zr-vault] reload failed: $e');
      }),
    );
    switch (outcome) {
      case LoginWebOutcome.done:
        await _manualReload('login-done');
      case LoginWebOutcome.fallbackPopup:
        // 改用既有弹窗通路：刷新页面，未登录态由宿主页自开 OAuth 弹窗。
        await _manualReload('login-fallback-popup');
      case LoginWebOutcome.dismissed:
      case null:
        break;
    }
  }

  Future<void> _openAccountVault() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AccountVaultPage(
          device: widget.device,
          onCaptureCurrent: _readCurrentCredentials,
          onApply: _applyAccountToWebView,
        ),
      ),
    );
    if (!mounted) return;
    unawaited(
      ref.read(accountsProvider.notifier).reload().catchError((Object e) {
        debugPrint('[zr-vault] reload failed: $e');
      }),
    );
  }

  Future<void> _confirmLogout() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.acctLogoutConfirmTitle),
        content: Text(l10n.acctLogoutConfirmBody),
        actions: [
          TextButton(
            key: const Key('acct-logout-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const Key('acct-logout-ok'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.acctLogout),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _logout();
  }

  Future<void> _logout() async {
    final l10n = AppLocalizations.of(context)!;
    final account = ref.read(accountsProvider).activeAccountOf(widget.device);
    var revokeError = '';
    if (account?.jwt != null && account!.jwt!.isNotEmpty) {
      try {
        await ZaiAuthClient().revokeAll(
          account.jwt!,
          deviceMid: account.virtualDeviceMid,
        );
      } catch (e) {
        debugPrint('[zr-vault] revoke-all failed: $e');
        revokeError = '$e';
      }
    }
    // 清本设备 localStorage 凭据仓 + 解除在用绑定 + reload。
    await _evaluateOnPage(AccountVault.credentialClearScript());
    await ref
        .read(accountsProvider.notifier)
        .setActiveForDevice(widget.device, null);
    if (!mounted) return;
    await _manualReload('logout');
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            revokeError.isEmpty
                ? l10n.acctLogoutDone
                : l10n.acctLogoutFailed(revokeError),
          ),
        ),
      );
  }

  Future<void> _showAccountSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final active = ref.read(accountsProvider).activeAccountOf(widget.device);
    await showZrSheet<void>(
      context: context,
      builder: (sheetContext) {
        final zt = sheetContext.zt;
        Widget action(String label, IconData icon, VoidCallback onTap) =>
            ListTile(
              leading: Icon(icon, size: 20, color: zt.textLo),
              title: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: zt.textHi,
                ),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                onTap();
              },
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                l10n.acctSessionActions,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: zt.textLo,
                ),
              ),
            ),
            action(l10n.loginEntry, Icons.login_rounded, () {
              unawaited(_openLogin());
            }),
            action(l10n.acctVaultEntry, Icons.account_circle_outlined, () {
              unawaited(_openAccountVault());
            }),
            if (active != null)
              action(l10n.acctLogout, Icons.logout_rounded, () {
                unawaited(_confirmLogout());
              }),
          ],
        );
      },
    );
  }

  UnmodifiableListView<UserScript> _userScripts(bool dark) =>
      UnmodifiableListView([
        UserScript(
          source: EventObserver.hookScriptFor(
            _dispatchPort ?? 0,
            _dispatchServer?.token ?? '',
          ),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: WebTheme.seedScript(dark),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]);

  Future<void> _syncWebTheme(bool dark) async {
    _appliedWebDark = dark;
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: WebTheme.applyScript(dark));
    } catch (_) {}
    try {
      await controller.removeAllUserScripts();
      await controller.addUserScripts(userScripts: _userScripts(dark));
    } catch (_) {}
  }

  Future<void> _manualReload([String via = 'manual']) async {
    debugPrint('[zr-resume] reload via=$via');
    _resumeProbeSeq++;
    setState(() {
      _loading = true;
      _errorShown = false;
    });
    _report(SessionStatus.loading);
    await _controller?.loadUrl(urlRequest: _freshRequest());
  }

  Future<void> _onLoadError() async {
    final now = DateTime.now();
    if (now.difference(_lastAutoReload).inSeconds >= 30) {
      _lastAutoReload = now;
      _report(SessionStatus.loading);
      await _controller?.loadUrl(urlRequest: _freshRequest());
      return;
    }
    if (mounted) {
      setState(() => _errorShown = true);
      _report(SessionStatus.error);
    }
  }

  Future<void> _showSwitcher() async {
    final devices = ref.read(deviceListProvider);
    final l10n = AppLocalizations.of(context)!;
    await showZrSheet<void>(
      context: context,
      builder: (sheetContext) {
        final zt = sheetContext.zt;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final d in devices) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: d.id == widget.device.id
                        ? zt.accentSubtle
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: d.id == widget.device.id
                        ? Border.all(color: zt.accentBorder)
                        : null,
                  ),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    leading: _Led(
                      status: ref.read(sessionStatusProvider)[d.id],
                    ),
                    title: Text(
                      d.displayName(l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: d.id == widget.device.id
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: d.id == widget.device.id ? zt.accent : zt.textHi,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        UnreadBadge(feed: ref.read(eventFeedProvider)[d.id]),
                        if (d.id == widget.device.id) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.check, color: zt.accent, size: 20),
                        ],
                      ],
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      ZrHaptics.tap();
                      final index = ref.read(deviceListProvider).indexOf(d);
                      ref.read(activeTabProvider.notifier).set(index);
                    },
                  ),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Divider(indent: 16, endIndent: 16, color: zt.hairline),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: Icon(Icons.tune, color: zt.textLo),
              title: Text(
                l10n.manageTitle,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: zt.textLo,
                ),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _goHome();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showSessionPanel() async {
    await showZrSheet<void>(
      context: context,
      isScrollControlled: true,
      maxHeightFactor: 0.72,
      builder: (sheetContext) {
        return Consumer(
          builder: (context, ref, _) {
            final sessionsMap = ref.watch(
              sessionIndexProvider,
            )[widget.device.id];
            final sorted = (sessionsMap?.values.toList() ?? <SessionState>[])
              ..sort(SessionRanking.compareSessions);
            final activeId = ref.watch(activeSessionProvider)[widget.device.id];
            return SessionPanelSheet(
              sessions: sorted,
              activeSessionId: activeId,
              deviceName: widget.device.displayName(
                AppLocalizations.of(context)!,
              ),
              onClose: () => Navigator.pop(sheetContext),
              onSessionTap: (sessionId) {
                Navigator.pop(sheetContext);
                _jumpToSession(sessionId);
              },
              onStopSession: (sessionId) => _stopGeneration(sessionId),
            );
          },
        );
      },
    );
  }

  Future<void> _jumpToSession(String sessionId) async {
    final controller = _controller;
    if (controller == null) return;
    final workspace = ref
        .read(sessionIndexProvider)[widget.device.id]?[sessionId]
        ?.workspace;
    try {
      await controller.evaluateJavascript(
        source: SessionJump.jumpScript(sessionId, workspace: workspace),
      );
    } catch (_) {}
  }

  /// P1-4：会话卡行内「停止」——stopGeneration（zcode-task 频道）。
  /// 失败提示用户在页面内操作（会话页兜底同款语义）。
  Future<void> _stopGeneration(String sessionId) async {
    final bridge = _rpcBridge;
    final l10n = AppLocalizations.of(context)!;
    if (bridge == null) {
      _showSessionNotReady();
      return;
    }
    final workspace = ref
        .read(sessionIndexProvider)[widget.device.id]?[sessionId]
        ?.workspacePath;
    final ok = await TaskActionsClient(
      bridge,
    ).stopGeneration(taskId: sessionId, workspacePath: workspace);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.approvalStopFailed)));
    }
  }

  Future<bool> _ensureServiceReady() async {
    final readiness =
        ref.read(serviceReadinessProvider)[widget.device.id] ??
        ServiceReadiness.unknown;
    if (!serviceNeedsProbe(readiness)) return true;
    final ready = await _probeServiceReady();
    if (ready != false) return true;
    _showSessionNotReady();
    return false;
  }

  Future<bool?> _probeServiceReady() async {
    final bridge = _rpcBridge;
    if (bridge == null) return null;
    final epoch = _readinessEpoch;
    final ready = await ServiceProbe.checkReady(bridge);
    if (!mounted || epoch != _readinessEpoch) return null;
    if (ready == true) {
      _reportServiceReadiness(ServiceReadiness.ready);
    } else if (ready == false) {
      _reportServiceReadiness(ServiceReadiness.unavailable);
    }
    return ready;
  }

  void _showSessionNotReady() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.sessionNotReadyHint),
      ),
    );
  }

  Future<void> _openAutomation() async {
    final bridge = _rpcBridge;
    if (bridge == null) {
      _showSessionNotReady();
      return;
    }
    if (!await _ensureServiceReady()) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AutomationPage(device: widget.device, bridge: bridge),
      ),
    );
  }

  Future<void> _openClaim() async {
    final bridge = _rpcBridge;
    if (bridge == null) {
      _showSessionNotReady();
      return;
    }
    if (!await _ensureServiceReady()) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ClaimPage(
          device: widget.device,
          bridge: bridge,
          onDiagnosticsPressed: _openDiagnostics,
        ),
      ),
    );
  }

  Future<void> _openUsage() async {
    final bridge = _rpcBridge;
    if (bridge == null) {
      _showSessionNotReady();
      return;
    }
    if (!await _ensureServiceReady()) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UsagePage(device: widget.device, bridge: bridge),
      ),
    );
  }

  Future<void> _openModelSettings() async {
    final bridge = _rpcBridge;
    if (bridge == null) {
      _showSessionNotReady();
      return;
    }
    if (!await _ensureServiceReady()) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ModelSettingsPage(device: widget.device, bridge: bridge),
      ),
    );
  }

  Future<void> _openDiagnostics() async {
    final bridge = _rpcBridge;
    if (bridge == null) {
      _showSessionNotReady();
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnosticsPage(
          device: widget.device,
          bridge: bridge,
          // 端点探测 billing/balance 用设备在用账号的 zai JWT。
          tokenProvider: () async => ticketsOfActiveAccount(
            ref.read(accountsProvider),
            widget.device,
          ).quotaTokens,
        ),
      ),
    );
  }

  Future<void> _openQuota() async {
    final bridge = _rpcBridge;
    if (bridge == null) {
      _showSessionNotReady();
      return;
    }
    if (!await _ensureServiceReady()) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QuotaPage(
          device: widget.device,
          bridge: bridge,
          // 设备在用账号的直连票据（额度通路 B）。
          tokenProvider: () async => ticketsOfActiveAccount(
            ref.read(accountsProvider),
            widget.device,
          ).quotaTokens,
        ),
      ),
    );
  }

  Future<void> _openRewards() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RewardsPage(
          device: widget.device,
          // 福利页 localStorage 五键（含登录门控 zcodejwttoken）。
          credentialsProvider: () async => ticketsOfActiveAccount(
            ref.read(accountsProvider),
            widget.device,
          ).rewardsCredentials,
        ),
      ),
    );
  }

  /// P1-6：桌面设置遥控。
  Future<void> _openDesktopSettings() async {
    final bridge = _rpcBridge;
    if (bridge == null) {
      _showSessionNotReady();
      return;
    }
    if (!await _ensureServiceReady()) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DesktopSettingsPage(device: widget.device, bridge: bridge),
      ),
    );
  }

  /// P1-8：资产只读浏览。
  Future<void> _openAssets() async {
    final bridge = _rpcBridge;
    if (bridge == null) {
      _showSessionNotReady();
      return;
    }
    if (!await _ensureServiceReady()) return;
    if (!mounted) return;
    // 实测：sessionIndex 的 workspacePath 全 null，宿主 localStorage 才有真实值。
    final hostWorkspace = await _ensureHostWorkspacePath();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AssetsPage(
          device: widget.device,
          bridge: bridge,
          hostWorkspacePath: hostWorkspace ?? _activeWorkspacePath(),
        ),
      ),
    );
  }

  /// 宿主当前工作区回退源。
  ///
  /// 实测（2026-11-15 P0-2）：`sessionIndexProvider` 里会话的 `workspacePath`
  /// 全为 null，真实值在宿主 localStorage `zcode-workspace-expansion`，
  /// 形状为 `Record<workspacePath, boolean>`（取首个 key），旧版本可能直接存路径串。
  Future<String?> _readHostWorkspacePath() async {
    final raw = await _evaluateOnPage(
      "localStorage.getItem('zcode-workspace-expansion')",
    );
    if (raw == null || raw.isEmpty || raw == 'null') return null;
    var value = raw.trim();
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    String? path;
    if (value.startsWith('{')) {
      try {
        final map = jsonDecode(value);
        if (map is Map && map.isNotEmpty) {
          final first = map.keys.first;
          if (first is String && first.isNotEmpty) path = first;
        }
      } catch (_) {}
    } else if (value.isNotEmpty) {
      path = value;
    }
    if (path != null && _hostWorkspacePath != path) {
      _hostWorkspacePath = path;
      if (mounted) setState(() {});
    }
    return path;
  }

  /// 宿主工作区（带缓存）：资产页 / Git 卡的回退源。
  Future<String?> _ensureHostWorkspacePath() async =>
      _hostWorkspacePath ?? await _readHostWorkspacePath();

  /// 当前（活动会话优先）工作区路径：Git 卡 / 资产页共用。
  String? _activeWorkspacePath() {
    final sessions = ref.read(sessionIndexProvider)[widget.device.id];
    if (sessions == null || sessions.isEmpty) return null;
    final activeId = ref.read(activeSessionProvider)[widget.device.id];
    return sessions[activeId]?.workspacePath ??
        sessions.values.map((s) => s.workspacePath).nonNulls.firstOrNull;
  }

  /// 领券入口能力探针：只回答「宿主有没有领券服务能力」。
  ///
  /// 业务态（无券可领 / 空 plans / manual_claim_preview_missing_data）
  /// **不得**写成不可用——那是「有可领」徽标的事（claimEntryProvider），
  /// 混用会让卡片被一次空结果永久锁死（修复前缺陷）。
  Future<void> _probeClaimEntry() async {
    final bridge = _rpcBridge;
    if (bridge == null) {
      debugPrint('claimEntry: probe skip（bridge 未就绪）');
      return;
    }
    final result = await ServiceProbe.checkClaimService(bridge);
    if (!mounted) return;
    debugPrint(
      'claimEntry: service available=${result.available} '
      'reason=${result.reason}',
    );
    _claimServiceNotifier?.mark(
      widget.device.id,
      result.available,
      reason: result.reason,
    );
  }

  @override
  void dispose() {
    // P2-1：会话销毁（设备移除/页面关闭）→ 自动领取停表。
    ref.read(claimSchedulerHubProvider.notifier).detach(widget.device.id);
    // P1-4：审批中心解绑。
    ref.read(approvalCenterProvider.notifier).detach(widget.device.id);
    _statusNotifier?.forget(widget.device.id);
    _feedNotifier?.forget(widget.device.id);
    _sessionIndexNotifier?.forget(widget.device.id);
    _activeSessionNotifier?.forget(widget.device.id);
    _automationNotifier?.forget(widget.device.id);
    _claimEntryNotifier?.forget(widget.device.id);
    _claimServiceNotifier?.forget(widget.device.id);
    _readinessNotifier?.forget(widget.device.id);
    _rpcBridge?.dispose();
    _dispatchServer?.dispose();
    _resumeGrace?.cancel();
    super.dispose();
  }

  /// JWT 过期前 24h 横幅（读账号库，P0-7）。
  Widget _buildJwtExpiringBanner(BuildContext context) {
    final account = ref.watch(accountsProvider).activeAccountOf(widget.device);
    if (account == null || !account.expiringSoon) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final exp = account.jwtExpAtMs;
    final hoursLeft = exp == null
        ? 1
        : ((exp - DateTime.now().millisecondsSinceEpoch) / 3600000)
              .ceil()
              .clamp(1, 999999);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.zt.warn.withValues(alpha: 0.10),
        border: Border(left: BorderSide(color: context.zt.warn, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded, size: 20, color: context.zt.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.loginJwtExpiringBanner(hoursLeft),
              key: const Key('jwt-expiring-banner'),
              style: TextStyle(fontSize: 12, color: context.zt.textLo),
            ),
          ),
          const SizedBox(width: 10),
          InkWell(
            key: const Key('jwt-expiring-relogin'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => unawaited(_openLogin()),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: context.zt.warn.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: context.zt.warn.withValues(alpha: 0.30),
                ),
              ),
              child: Text(
                l10n.loginRelogin,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: context.zt.warn,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(sessionStatusProvider)[widget.device.id];
    final l10n = AppLocalizations.of(context)!;
    ref.listen(appLifecycleProvider, (prev, next) {
      if (next == prev) return;
      debugPrint('[zr-resume] lifecycle $prev -> $next');
      _resumeWatch.onState(next, DateTime.now());
      if (next == AppLifecycleState.resumed &&
          prev != AppLifecycleState.resumed) {
        _onAppResume();
      }
    });
    // P2-1：仅设备 live 时运行自动领取轮次。
    ref.listen(sessionStatusProvider, (prev, next) {
      ref
          .read(claimSchedulerHubProvider.notifier)
          .setLive(
            widget.device.id,
            next[widget.device.id] == SessionStatus.live,
          );
    });
    // P2-5：配置变更（开关/静默时段）实时作用于调度代理。
    ref.listen(claimConfigProvider, (prev, next) {
      final config = next[widget.device.id];
      if (config != null) {
        ref
            .read(claimSchedulerHubProvider.notifier)
            .updateConfig(widget.device.id, config);
      }
    });
    // P2-7：领取结果通知点击 → 打开本设备领取页。
    ref.listen(claimOpenRequestProvider, (prev, next) {
      if (next == null || next != widget.device.id) return;
      ref.read(claimOpenRequestProvider.notifier).consume();
      _openClaim();
    });
    // P4-7：通知直达 → 定位具体会话（webview 内滚动展开）。
    ref.listen(sessionJumpRequestProvider, (prev, next) {
      if (next == null || next.deviceId != widget.device.id) return;
      _jumpToSession(next.sessionId);
    });
    // P3-7：设置页「连接诊断」入口 → 打开本设备诊断页。
    ref.listen(diagnosticsOpenRequestProvider, (prev, next) {
      if (next == null || next.deviceId != widget.device.id) return;
      _openDiagnostics();
    });
    if (!_claimEntryProbed &&
        status == SessionStatus.live &&
        _rpcBridge != null) {
      _claimEntryProbed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _probeClaimEntry();
      });
    } else if (status != SessionStatus.live) {
      // 离 live 后允许再次探测（否则卡片状态会停在最后一次读数上）。
      _claimEntryProbed = false;
    }
    final webDark = Theme.of(context).brightness == Brightness.dark;
    if (_appliedWebDark != webDark) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncWebTheme(webDark);
      });
    }

    final devices = ref.watch(deviceListProvider);
    final activeTab = ref.watch(activeTabProvider);
    final isActive =
        activeTab < devices.length && devices[activeTab].id == widget.device.id;

    return PopScope(
      canPop: !isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!isActive || didPop) return;
        final scaffoldState = _scaffoldKey.currentState;
        if (scaffoldState != null && scaffoldState.isEndDrawerOpen) {
          scaffoldState.closeEndDrawer();
          return;
        }
        if (scaffoldState != null && scaffoldState.isDrawerOpen) {
          scaffoldState.closeDrawer();
          return;
        }
        ref
            .read(activeTabProvider.notifier)
            .set(ref.read(deviceListProvider).length);
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.tune),
            tooltip: l10n.manageTitle,
            onPressed: _goHome,
          ),
          title: Tooltip(
            message: l10n.sessionTitleTooltip(widget.device.displayName(l10n)),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _showSwitcher,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Led(status: status),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.device.displayName(l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                          color: context.zt.textHi,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.expand_more, size: 20, color: context.zt.textLo),
                  ],
                ),
              ),
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(2),
            child: _loading
                ? const LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                  )
                : const SizedBox(height: 2, width: double.infinity),
          ),
          actions: [
            if (widget.device.kind == DeviceKind.v2)
              IconButton(
                key: const Key('session-account-entry'),
                icon: const Icon(Icons.account_circle_outlined),
                tooltip: l10n.loginAccountMenu,
                onPressed: _showAccountSheet,
              ),
            _ToolboxEntryButton(
              device: widget.device,
              onAutomationPressed: _openAutomation,
              onClaimPressed: _openClaim,
              onUsagePressed: _openUsage,
              onModelSettingsPressed: _openModelSettings,
              onDiagnosticsPressed: _openDiagnostics,
              onQuotaPressed: _openQuota,
              onRewardsPressed: _openRewards,
              onDesktopSettingsPressed: _openDesktopSettings,
              onAssetsPressed: _openAssets,
              gitClient: _rpcBridge == null
                  ? null
                  : GitOverviewClient(_rpcBridge!),
              workspacePath: _activeWorkspacePath() ?? _hostWorkspacePath,
              onOpened: () {
                // 开面板即复查领券能力（灰卡自愈）并预热宿主工作区缓存。
                unawaited(_probeClaimEntry());
                unawaited(_ensureHostWorkspacePath());
              },
            ),
            IconButton(
              icon: const Icon(Icons.article_outlined),
              tooltip: l10n.sessionsPanelTooltip,
              onPressed: _showSessionPanel,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.refreshTooltip,
              onPressed: _manualReload,
            ),
          ],
        ),
        body: Column(
          children: [
            AnimatedSize(
              duration: ZrMotion.duration(240),
              curve: ZrMotion.curve,
              child: _errorShown
                  ? Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: context.zt.danger.withValues(alpha: 0.10),
                        border: Border(
                          left: BorderSide(color: context.zt.danger, width: 3),
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 20,
                            color: context.zt.danger,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.statusError,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: context.zt.danger,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  l10n.errorBannerDetail,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.zt.textLo,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          _ErrorRetryButton(onPressed: _manualReload),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            AnimatedSize(
              duration: ZrMotion.duration(240),
              curve: ZrMotion.curve,
              child:
                  shouldShowIsolationFallback(
                    kind: widget.device.kind,
                    multiProfileSupported:
                        ref.watch(multiProfileSupportedProvider).value ?? true,
                  )
                  ? Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: context.zt.warn.withValues(alpha: 0.10),
                        border: Border(
                          left: BorderSide(color: context.zt.warn, width: 3),
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 20,
                            color: context.zt.warn,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              l10n.webviewIsolationUnsupportedHint,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.zt.textLo,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              child: _buildJwtExpiringBanner(context),
            ),
            Expanded(
              child: ColoredBox(
                color: context.zt.bg,
                child: _dispatchPort == null
                    ? const SizedBox.expand()
                    : InAppWebView(
                        initialUrlRequest: _freshRequest(),
                        initialUserScripts: _userScripts(webDark),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          domStorageEnabled: true,
                          supportZoom: false,
                          transparentBackground: true,
                          useHybridComposition: false,
                          supportMultipleWindows: true,
                          javaScriptCanOpenWindowsAutomatically: true,
                          androidWebProfile: webProfileNameFor(widget.device),
                          // P3-7：桌面 UA 覆写实验开关（构造时应用，重开会话生效）。
                          userAgent: desktopUaFor(ref.watch(uaDesktopProvider)),
                        ),
                        onCreateWindow: (controller, action) async =>
                            _openAuthPopup(action),
                        onRenderProcessGone: (_, detail) {
                          debugPrint('[zr-resume] rendererGone detail=$detail');
                          _rendererGone = true;
                          if (!mounted) return;
                          if (ref.read(appLifecycleProvider) ==
                              AppLifecycleState.resumed) {
                            _rendererGone = false;
                            _manualReload();
                          }
                        },
                        onWebViewCreated: (controller) {
                          _controller = controller;
                          if (kDebugMode) {
                            InAppWebViewController.setWebContentsDebuggingEnabled(
                              true,
                            );
                            debugPrint(
                              '[zr-diag] webview created dev=${widget.device.id}',
                            );
                          }
                          _rpcBridge = RpcBridge(
                            deviceId: widget.device.id,
                            dispatch: _dispatchServer!,
                            onServiceState: widget.device.kind == DeviceKind.v2
                                ? (ready) => _reportServiceReadiness(
                                    ready
                                        ? ServiceReadiness.ready
                                        : ServiceReadiness.unavailable,
                                  )
                                : null,
                          );
                          // P2-1：自动领取装配（通路 A 宿主 RPC）。
                          unawaited(
                            ref
                                .read(claimSchedulerHubProvider.notifier)
                                .attach(widget.device, _rpcBridge!),
                          );
                          // P1-4：审批动作客户端注册（通知动作按钮回执）。
                          ref
                              .read(approvalCenterProvider.notifier)
                              .attach(widget.device.id, _rpcBridge!);
                          controller.addJavaScriptHandler(
                            handlerName: 'zrEvents',
                            callback: (args) {
                              final body = args.isNotEmpty ? args.first : null;
                              if (body is String) _onBridgeMessage(body);
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'zrViewState',
                            callback: (args) {
                              final body = args.isNotEmpty ? args.first : null;
                              if (body is String) _onViewStateSync(body);
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'zrWs',
                            callback: (args) {
                              final body = args.isNotEmpty ? args.first : null;
                              if (body is String) _onWsEvent(body);
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'zrSvcResult',
                            callback: (args) {
                              final body = args.isNotEmpty ? args.first : null;
                              if (body is String) _rpcBridge?.onSvcResult(body);
                              return null;
                            },
                          );
                        },
                        onLoadStart: (_, _) {
                          if (mounted) {
                            setState(() {
                              _loading = true;
                              _errorShown = false;
                            });
                            _report(SessionStatus.loading);
                            _automationNotifier?.reportSubscribed(
                              widget.device.id,
                              false,
                            );
                            _rpcBridge?.resetOffPeakProbe();
                            _rpcBridge?.resetServiceResolution();
                            _probeArmed = true;
                            _readinessEpoch++;
                            _readinessNotifier?.reset(widget.device.id);
                            _claimEntryProbed = false;
                            _claimEntryNotifier?.reset(widget.device.id);
                            _claimServiceNotifier?.reset(widget.device.id);
                          }
                        },
                        onLoadStop: (_, _) {
                          if (mounted) {
                            setState(() => _loading = false);
                            _syncWebTheme(
                              Theme.of(context).brightness == Brightness.dark,
                            );
                            if (widget.device.kind == DeviceKind.v2) {
                              unawaited(_probeServiceReady());
                            }
                            // 错误恢复后复查领券服务能力（灰卡自愈）。
                            unawaited(_probeClaimEntry());
                            unawaited(_ensureHostWorkspacePath());
                          }
                        },
                        onReceivedError: (controller, request, error) async {
                          if (!mounted) return;
                          if (!PageLoadPolicy.isMainDocFailure(
                            request.isForMainFrame,
                          )) {
                            return;
                          }
                          setState(() => _loading = false);
                          await _onLoadError();
                        },
                        onReceivedHttpError:
                            (controller, request, errorResponse) async {
                              if (!mounted) return;
                              if (!PageLoadPolicy.isHttpFailure(
                                request.isForMainFrame,
                                errorResponse.statusCode,
                              )) {
                                return;
                              }
                              setState(() => _loading = false);
                              await _onLoadError();
                            },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Led extends StatelessWidget {
  const _Led({required this.status});

  final SessionStatus? status;

  @override
  Widget build(BuildContext context) {
    return StatusLed(status: status, size: 8, showGlow: true);
  }
}

class _ToolboxEntryButton extends ConsumerWidget {
  const _ToolboxEntryButton({
    required this.device,
    required this.onAutomationPressed,
    required this.onClaimPressed,
    required this.onUsagePressed,
    required this.onModelSettingsPressed,
    this.onDiagnosticsPressed,
    this.onQuotaPressed,
    this.onRewardsPressed,
    this.onDesktopSettingsPressed,
    this.onAssetsPressed,
    this.gitClient,
    this.workspacePath,
    this.onOpened,
  });

  final RemoteDevice device;

  /// 打开工具箱前的钩子（复查领券能力 / 预热宿主工作区缓存）。
  final VoidCallback? onOpened;

  final VoidCallback onAutomationPressed;
  final VoidCallback onClaimPressed;
  final VoidCallback onUsagePressed;
  final VoidCallback onModelSettingsPressed;
  final VoidCallback? onDiagnosticsPressed;
  final VoidCallback? onQuotaPressed;
  final VoidCallback? onRewardsPressed;
  final VoidCallback? onDesktopSettingsPressed;
  final VoidCallback? onAssetsPressed;

  /// P1-7：Git 概览数据源（null 时 Git 卡置灰）。
  final GitOverviewClient? gitClient;

  /// P1-7：Git 卡的 workspacePath。
  final String? workspacePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autoBoard = ref.watch(automationProvider)[device.id];
    final claimReady = ref.watch(claimEntryProvider)[device.id] == true;
    // P1-9：审批待办并入工具箱入口徽标（event_feed 的 permPending）。
    final permPending =
        ref.watch(eventFeedProvider)[device.id]?.permPending ?? false;
    final hasActiveNotice =
        (autoBoard?.queuedCount ?? 0) > 0 || claimReady || permPending;

    return IconButton(
      icon: Badge(
        isLabelVisible: hasActiveNotice,
        smallSize: 8,
        backgroundColor: context.zt.danger,
        child: const Icon(Icons.grid_view_rounded, size: 20),
      ),
      tooltip: AppLocalizations.of(context)!.toolboxTitle,
      onPressed: () {
        onOpened?.call();
        showToolboxSheet(
          context: context,
          device: device,
          onAutomationPressed: onAutomationPressed,
          onClaimPressed: onClaimPressed,
          onUsagePressed: onUsagePressed,
          onModelSettingsPressed: onModelSettingsPressed,
          onDiagnosticsPressed: onDiagnosticsPressed,
          onQuotaPressed: onQuotaPressed,
          onRewardsPressed: onRewardsPressed,
          onDesktopSettingsPressed: onDesktopSettingsPressed,
          onAssetsPressed: onAssetsPressed,
          gitClient: gitClient,
          workspacePath: workspacePath,
        );
      },
    );
  }
}

class ClaimEntryButton extends ConsumerWidget {
  const ClaimEntryButton({
    super.key,
    required this.deviceId,
    required this.onPressed,
  });

  final String deviceId;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(claimEntryProvider)[deviceId] == true;
    return AnimatedSwitcher(
      duration: ZrMotion.duration(120),
      child: visible
          ? IconButton(
              key: const ValueKey('claim-entry-on'),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Badge(
                backgroundColor: context.zt.accent,
                child: const Icon(Icons.card_giftcard, size: 20),
              ),
              tooltip: AppLocalizations.of(context)!.claimEntryTooltip,
              onPressed: onPressed,
            )
          : const SizedBox.shrink(key: ValueKey('claim-entry-off')),
    );
  }
}

class _ErrorRetryButton extends StatelessWidget {
  const _ErrorRetryButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: zt.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: zt.danger.withValues(alpha: 0.30)),
        ),
        child: Text(
          AppLocalizations.of(context)!.retry,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: zt.danger,
          ),
        ),
      ),
    );
  }
}
