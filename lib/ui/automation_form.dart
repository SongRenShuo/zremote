import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/device.dart';
import '../models/device_label.dart';
import '../services/rpc_bridge.dart';
import '../services/rpc_codec.dart';
import '../state/automation.dart';
import '../state/session_status.dart';
import '../theme.dart';
import 'automation_page.dart';
import 'hw_chip.dart';
import 'showcase_bits.dart';

enum AutomationFormKind { offPeak, scheduled }

enum CronPreset { daily, weekdays, weekend, custom }

/// 自动化表单权限模式——对齐开源版 ZCode（packages/shared/src/
/// zcode-agent-model-state.ts 的 ZCODE_AGENT_MODE_OPTIONS）：自动化菜单只出
/// build/guarded/plan/yolo 四值；default/edit 不进菜单，但 edit 作为历史值
/// 仍被会话恢复保留（菜单隐藏不等于删除历史值）。
const List<String> kPermissionModes = [
  'build',
  'guarded',
  'plan',
  'yolo',
];

const Map<String, Object> kModelSelection = {
  'providerId': 'builtin:bigmodel-coding-plan',
  'modelId': 'GLM-5.3',
  'options': {'reasoningLevel': 'max'},
};

/// modelSelection.getView() 解析出的可选模型（2026-11-14 CDP 实测形状：
/// providers[].models[].{modelId, config.optionSpecs.reasoningLevel.values}）。
class AutomationModelOption {
  const AutomationModelOption({
    required this.providerId,
    required this.providerName,
    required this.modelId,
    required this.reasoningLevels,
  });

  final String providerId;
  final String providerName;
  final String modelId;
  final List<String> reasoningLevels;

  String get key => '$providerId|$modelId';
  String get label => providerName.isEmpty
      ? modelId
      : '$providerName · $modelId';
}

class AutomationCreateRejectedException implements Exception {
  const AutomationCreateRejectedException(this.errorCategory);

  final String? errorCategory;
}

class AutomationFormPage extends ConsumerStatefulWidget {
  const AutomationFormPage({
    super.key,
    required this.bridge,
    required this.kind,
    this.device,
    this.editing,
    this.editingOffPeak,
    this.prefillTitle,
    this.prefillPrompt,
  });

  final RpcBridge bridge;

  final AutomationFormKind kind;

  final RemoteDevice? device;

  final Automation? editing;

  final OffPeakTask? editingOffPeak;

  final String? prefillTitle;
  final String? prefillPrompt;

  static Map<String, Object> buildCreateTaskPayload({
    required String title,
    required String prompt,
    required String workspacePath,
    required String permissionMode,
    String modelId = 'GLM-5.3',
    String thoughtLevel = 'max',
    Map<String, Object>? modelSelection,
  }) => {
    'title': title,
    'prompt': prompt,
    'workspacePath': workspacePath,
    'permissionMode': permissionMode,
    'model': modelId,
    'thoughtLevel': thoughtLevel,
    'modelSelection': modelSelection ?? kModelSelection,
  };

  static Map<String, dynamic> buildCreateAutomationPayload({
    required String workspacePath,
    required String title,
    required String cronExpr,
    required String prompt,
    required String mode,
    String modelId = 'GLM-5.3',
    String thoughtLevel = 'max',
    Map<String, Object>? modelSelection,
  }) => {
    'workspacePath': workspacePath,
    'title': title,
    'cronExpr': cronExpr,
    'prompt': prompt,
    'recurring': true,
    'mode': mode,
    'thoughtLevel': thoughtLevel,
    'model': RpcCodec.kScheduledModel,
    'modelSelection': modelSelection ?? kModelSelection,
  };

  static Map<String, dynamic> buildUpdateTaskDiff({
    required String title,
    required String prompt,
    required String permissionMode,
    required String originalPermissionMode,
    required OffPeakTask editing,
  }) {
    final params = <String, dynamic>{};
    if (title != editing.title) params['title'] = title;
    if (prompt != editing.prompt) params['prompt'] = prompt;
    if (permissionMode != originalPermissionMode) {
      params['permissionMode'] = permissionMode;
    }
    return params;
  }

  static String createFailureMessage(Object error, AppLocalizations l10n) {
    if (error is AutomationCreateRejectedException) {
      switch (error.errorCategory) {
        case 'eligibility_3101':
          return l10n.automationCreateEligibility;
        case 'quota_3103':
          return l10n.automationCreateQuota;
        case 'client_validation':
          return l10n.automationCreateValidation;
        case 'network':
          return l10n.automationCreateNetwork;
      }
      return l10n.automationOpFailed;
    }
    if (error is RpcRemoteException &&
        error.message.contains('AUTOMATION_CREATE_LIMIT_REACHED')) {
      return l10n.automationCreateLimitReached;
    }
    return l10n.automationOpFailed;
  }

  @override
  ConsumerState<AutomationFormPage> createState() => _AutomationFormPageState();
}

class _AutomationFormPageState extends ConsumerState<AutomationFormPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool get _isCreate => widget.editing == null && widget.editingOffPeak == null;

  late AutomationFormKind _kind = widget.editing != null
      ? AutomationFormKind.scheduled
      : widget.editingOffPeak != null
      ? AutomationFormKind.offPeak
      : widget.kind;

  late final TextEditingController _title = TextEditingController(
    text:
        widget.editing?.title ??
        widget.editingOffPeak?.title ??
        widget.prefillTitle ??
        '',
  );
  late final TextEditingController _prompt = TextEditingController(
    text:
        widget.editing?.prompt ??
        widget.editingOffPeak?.prompt ??
        widget.prefillPrompt ??
        '',
  );
  final TextEditingController _cron = TextEditingController();
  final TextEditingController _manualWorkspace = TextEditingController();

  CronPreset _preset = CronPreset.daily;
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  String? _workspace;
  String _permissionMode = 'build';

  String _originalPermissionMode = 'build';
  bool _submitting = false;

  AutomationNotifier? _notifier;

  // 模型/思考级别（宿主 modelSelection.getView 动态加载；失败降级硬编码兜底）。
  List<AutomationModelOption> _modelOptions = const [];
  String? _selectedModelKey;
  String _modelId = 'GLM-5.3';
  String _thoughtLevel = 'max';

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(automationProvider.notifier);
    final editing = widget.editing;
    if (editing != null) {
      _workspace = editing.workspacePath;
      _preset = _detectPreset(editing.cronExpr);
      _cron.text = editing.cronExpr;
      if (editing.mode.isNotEmpty) {
        _permissionMode = editing.mode;
        _originalPermissionMode = editing.mode;
      }
      final parts = editing.cronExpr.trim().split(RegExp(r'\s+'));
      if (parts.length == 5) {
        final minute = int.tryParse(parts[0]);
        final hour = int.tryParse(parts[1]);
        if (minute != null && hour != null) {
          _time = TimeOfDay(hour: hour, minute: minute);
        }
      }
    }
    final task = widget.editingOffPeak;
    if (task != null) {
      _workspace = task.workspacePath;
      _permissionMode = task.permissionMode;
      _originalPermissionMode = task.permissionMode;
    }
    // 编辑回填：宿主 automations 的模型数据在 modelSelection.modelId /
    // options.reasoningLevel（Automation.fromJson 已归一进 model/thoughtLevel）。
    if (editing != null && editing.model.isNotEmpty) {
      _modelId = editing.model;
      if (editing.thoughtLevel.isNotEmpty) {
        _thoughtLevel = editing.thoughtLevel;
      }
    }
    unawaited(_loadSelection());
  }

  /// 从宿主 modelSelection.getView 加载可选模型与各模型的思考级别档位。
  /// 失败静默降级：UI 回落硬编码兜底 chip（保持旧形态可用）。
  Future<void> _loadSelection() async {
    try {
      final r = await widget.bridge.call(
        'model-selection',
        'getView',
        timeout: const Duration(seconds: 20),
      );
      final view = r.firstObjectDeep ?? const {};
      final providers = view['providers'] as List? ?? const [];
      final options = <AutomationModelOption>[];
      for (final p in providers) {
        if (p is! Map<String, dynamic>) continue;
        final pid = p['providerId'] is String
            ? p['providerId'] as String
            : '';
        final pname = p['providerName'] is String
            ? p['providerName'] as String
            : pid;
        for (final m in (p['models'] as List? ?? const [])) {
          if (m is! Map<String, dynamic>) continue;
          final mid = m['modelId'] is String ? m['modelId'] as String : '';
          if (mid.isEmpty) continue;
          final levels = ((((m['config'] as Map?)?['optionSpecs'] as Map?)?['reasoningLevel'] as Map?)?['values']);
          options.add(
            AutomationModelOption(
              providerId: pid,
              providerName: pname,
              modelId: mid,
              reasoningLevels: [
                if (levels is List) for (final l in levels) if (l is String) l,
              ],
            ),
          );
        }
      }
      if (options.isEmpty) return;
      // 默认选中 preferredSelection；编辑态优先匹配回填的 modelId。
      String? pickKey;
      String? pickLevel;
      final pref = view['preferredSelection'];
      if (pref is Map<String, dynamic>) {
        final pid = pref['providerId'] is String ? pref['providerId'] as String : '';
        final mid = pref['modelId'] is String ? pref['modelId'] as String : '';
        if (mid.isNotEmpty) pickKey = '$pid|$mid';
        final lv = ((pref['options'] as Map?)?['reasoningLevel']);
        pickLevel = lv is String ? lv : null;
      }
      if (widget.editing != null) {
        final match = options.where((o) => o.modelId == _modelId).toList();
        if (match.isNotEmpty) {
          pickKey = match.first.key;
          if (match.first.reasoningLevels.contains(_thoughtLevel)) {
            pickLevel = _thoughtLevel;
          } else {
            pickLevel = null;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _modelOptions = options;
        _selectedModelKey =
            pickKey != null && options.any((o) => o.key == pickKey)
            ? pickKey
            : options.first.key;
        final picked = options.firstWhere(
          (o) => o.key == _selectedModelKey,
          orElse: () => options.first,
        );
        _modelId = picked.modelId;
        _thoughtLevel =
            pickLevel != null && picked.reasoningLevels.contains(pickLevel)
            ? pickLevel
            : (picked.reasoningLevels.isNotEmpty
                  ? picked.reasoningLevels.last
                  : 'max');
      });
    } catch (e) {
      debugPrint('[automation-form] modelSelection load failed: $e');
    }
  }

  AutomationModelOption? get _pickedModel {
    for (final o in _modelOptions) {
      if (o.key == _selectedModelKey) return o;
    }
    return null;
  }

  /// 当前选择的 modelSelection 载荷；未加载成功时返回 null（payload 走兜底）。
  Map<String, Object>? get _modelSelectionPayload {
    final picked = _pickedModel;
    if (picked == null) return null;
    return {
      'providerId': picked.providerId,
      'modelId': _modelId,
      'options': {'reasoningLevel': _thoughtLevel},
    };
  }

  /// 权限模式中文标签（未知值回落原文，兼容宿主新增枚举）。
  String _permissionLabel(AppLocalizations l10n, String mode) => switch (mode) {
    'build' => l10n.automationModeBuild,
    'guarded' => l10n.automationModeGuarded,
    'plan' => l10n.automationModePlan,
    'yolo' => l10n.automationModeYolo,
    'default' => l10n.automationModeDefault,
    'edit' => l10n.automationModeEdit,
    _ => mode,
  };

  /// 官方描述（zh-CN locale mode.description.glm.*）。
  String _permissionDesc(AppLocalizations l10n, String mode) => switch (mode) {
    'build' => l10n.automationModeDescBuild,
    'guarded' => l10n.automationModeDescGuarded,
    'plan' => l10n.automationModeDescPlan,
    'yolo' => l10n.automationModeDescYolo,
    'default' => l10n.automationModeDescDefault,
    'edit' => l10n.automationModeDescEdit,
    _ => '',
  };

  /// 思考级别中文显示（官方 offPeak.thought.*：低/高/最高）。
  String _thoughtLabel(AppLocalizations l10n, String level) => switch (level) {
    'low' => l10n.automationThoughtLow,
    'high' => l10n.automationThoughtHigh,
    'max' => l10n.automationThoughtMax,
    _ => level,
  };

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    _cron.dispose();
    _manualWorkspace.dispose();
    super.dispose();
  }

  List<String> _candidates(AutomationBoard board) {
    final set = <String>{
      ...board.recentProjects,
      ...board.automations.map((a) => a.workspacePath),
      ...board.offPeak.map((t) => t.workspacePath),
    }..removeWhere((p) => p.isEmpty);
    return set.toList()..sort();
  }

  String get _cronExpr {
    if (_preset == CronPreset.custom) return _cron.text.trim();
    final dow = switch (_preset) {
      CronPreset.weekdays => '1-5',
      CronPreset.weekend => '6,0',
      _ => '*',
    };
    return '${_time.minute} ${_time.hour} * * $dow';
  }

  static CronPreset _detectPreset(String? cronExpr) {
    if (cronExpr == null) return CronPreset.daily;
    final parts = cronExpr.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return CronPreset.custom;
    final minute = parts[0],
        hour = parts[1],
        dom = parts[2],
        mon = parts[3],
        dow = parts[4];
    if (dom != '*' || mon != '*') return CronPreset.custom;
    final numeric = int.tryParse(hour) != null && int.tryParse(minute) != null;
    if (dow == '1-5' && numeric) return CronPreset.weekdays;
    if ((dow == '6,0' || dow == '0,6') && numeric) return CronPreset.weekend;
    if (dow == '*' && numeric) return CronPreset.daily;
    return CronPreset.custom;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;
    final editingTask = widget.editingOffPeak;
    if (editingTask != null &&
        editingTask.status != 'queued' &&
        editingTask.status != 'paused') {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final board =
        ref.read(automationProvider)[widget.bridge.deviceId] ??
        const AutomationBoard();
    final candidates = _candidates(board);
    final selected = _selectedWorkspace(candidates);
    final workspace = candidates.isNotEmpty ? selected! : _manualWorkspace.text;
    final title = _title.text.trim();
    final prompt = _prompt.text.trim();
    setState(() => _submitting = true);
    try {
      if (_kind == AutomationFormKind.offPeak) {
        if (editingTask != null) {
          final diffs = AutomationFormPage.buildUpdateTaskDiff(
            title: title,
            prompt: prompt,
            permissionMode: _permissionMode,
            originalPermissionMode: _originalPermissionMode,
            editing: editingTask,
          );
          final twoArgs = await widget.bridge.offPeakUpdateTwoArgs();
          final r = twoArgs
              ? await widget.bridge.callArgs(
                  'off-peak-task',
                  'updateTask',
                  args: [editingTask.offPeakTaskId, diffs],
                )
              : await widget.bridge.call(
                  'off-peak-task',
                  'updateTask',
                  params: {
                    'taskId': editingTask.offPeakTaskId,
                    ...diffs,
                  },
                );
          final obj = r.firstObject;
          if (obj == null || obj['offPeakTaskId'] == null) {
            throw StateError('updateTask 响应缺 offPeakTaskId');
          }
          _notifier?.upsertOffPeak(widget.bridge.deviceId, obj);
        } else {
          final r = await widget.bridge.call(
            'off-peak-task',
            'createTask',
            params: AutomationFormPage.buildCreateTaskPayload(
              title: title,
              prompt: prompt,
              workspacePath: workspace,
              permissionMode: _permissionMode,
              modelId: _modelId,
              thoughtLevel: _thoughtLevel,
              modelSelection: _modelSelectionPayload,
            ),
          );
          final obj = r.firstObject;
          if (obj != null && obj['ok'] == false) {
            throw AutomationCreateRejectedException(
              obj['errorCategory'] is String
                  ? obj['errorCategory'] as String
                  : null,
            );
          }
          final task = obj?['task'];
          if (task is! Map<String, dynamic> || task['offPeakTaskId'] == null) {
            throw StateError('createTask 响应缺 task.offPeakTaskId');
          }
          _notifier?.upsertOffPeak(widget.bridge.deviceId, task);
        }
      } else {
        final editing = widget.editing;
        if (editing != null) {
          final params = <String, dynamic>{
            'workspacePath': workspace,
            'automationId': editing.automationId,
          };
          if (title != editing.title) params['title'] = title;
          if (prompt != editing.prompt) params['prompt'] = prompt;
          final cron = _cronExpr;
          if (cron != editing.cronExpr) params['cronExpr'] = cron;
          if (_permissionMode != _originalPermissionMode) {
            params['mode'] = _permissionMode;
          }
          final r = await widget.bridge.call(
            'zcode-agent',
            'updateAutomation',
            params: params,
          );
          final obj = r.firstObject;
          if (obj == null || obj['automationId'] == null) {
            throw StateError('updateAutomation 响应缺 automationId');
          }
          _notifier?.upsertAutomation(widget.bridge.deviceId, obj);
        } else {
          final r = await widget.bridge.call(
            'zcode-agent',
            'createAutomation',
            params: AutomationFormPage.buildCreateAutomationPayload(
              workspacePath: workspace,
              title: title,
              cronExpr: _cronExpr,
              prompt: prompt,
              mode: _permissionMode,
              modelId: _modelId,
              thoughtLevel: _thoughtLevel,
              modelSelection: _modelSelectionPayload,
            ),
          );
          final obj = r.firstObject;
          if (obj == null || obj['automationId'] == null) {
            throw StateError('createAutomation 响应缺 automationId');
          }
          _notifier?.upsertAutomation(widget.bridge.deviceId, obj);
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.automationSaved)));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AutomationFormPage.createFailureMessage(e, l10n)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _selectedWorkspace(List<String> candidates) {
    if (candidates.isEmpty) return null;
    if (_workspace != null && candidates.contains(_workspace)) {
      return _workspace;
    }
    if (_workspace != null && _workspace!.isNotEmpty) return _workspace;
    return candidates.first;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final board =
        ref.watch(automationProvider)[widget.bridge.deviceId] ??
        const AutomationBoard();
    final candidates = _candidates(board);
    final editingLocked = !_isCreate;
    final device = widget.device;
    final deviceStatus = device == null
        ? null
        : ref.watch(sessionStatusProvider)[device.id];
    final deviceLive = deviceStatus == SessionStatus.live;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          editingLocked
              ? l10n.automationFormEdit
              : (_kind == AutomationFormKind.offPeak
                    ? l10n.automationFormNew
                    : l10n.automationFormNewScheduled),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        actions: [
          TextButton(
            onPressed: _submitting ? null : _submit,
            style: TextButton.styleFrom(
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
            child: Text(l10n.commonSave),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (device != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: context.zt.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.zt.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.formTargetLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: context.zt.textLo,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: deviceLive
                                ? context.zt.live
                                : context.zt.danger,
                            boxShadow: [
                              BoxShadow(
                                color: (deviceLive
                                        ? context.zt.live
                                        : context.zt.danger)
                                    .withValues(alpha: 0.35),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            device.displayName(l10n),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: context.zt.textHi,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            if (_isCreate) ...[
              ZrSegmented(
                segments: [
                  ('off', l10n.automationKindOffPeak),
                  ('sched', l10n.automationKindScheduled),
                ],
                active: _kind == AutomationFormKind.offPeak ? 'off' : 'sched',
                onChanged: (value) => setState(
                  () => _kind = value == 'off'
                      ? AutomationFormKind.offPeak
                      : AutomationFormKind.scheduled,
                ),
              ),
              const SizedBox(height: 14),
            ],
            if (_kind == AutomationFormKind.offPeak) ...[
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                decoration: BoxDecoration(
                  color: context.zt.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.zt.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.presetLabel,
                      style: TextStyle(fontSize: 11, color: context.zt.textLo),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _presetChip(
                          icon: Icons.replay_rounded,
                          label: l10n.presetGitBackup,
                          onTap: () => _prompt.text = l10n.presetGitBackup,
                        ),
                        _presetChip(
                          icon: Icons.shield_outlined,
                          label: l10n.presetSecurityAudit,
                          onTap: () => _prompt.text = l10n.presetSecurityAudit,
                        ),
                        _presetChip(
                          icon: Icons.delete_outline,
                          label: l10n.presetBuildClean,
                          onTap: () => _prompt.text = l10n.presetBuildClean,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            ZrField(
              label: _kind == AutomationFormKind.offPeak
                  ? l10n.automationFieldTitle
                  : l10n.automationFieldTitleScheduled,
              child: TextFormField(
                controller: _title,
                decoration: zrInputDecoration(
                  context,
                  hint: _kind == AutomationFormKind.offPeak
                      ? l10n.automationFieldTitleHint
                      : l10n.automationFieldTitleHintScheduled,
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? l10n.automationTitleRequired
                    : null,
              ),
            ),
            const SizedBox(height: 14),
            if (_kind == AutomationFormKind.scheduled) ..._scheduleFields(l10n),
            ZrField(
              label: _kind == AutomationFormKind.offPeak
                  ? l10n.automationFieldPrompt
                  : l10n.automationFieldPromptScheduled,
              child: TextFormField(
                controller: _prompt,
                maxLines: 5,
                maxLength: 4000,
                style: const TextStyle(fontSize: 13, height: 1.5),
                decoration: zrInputDecoration(context),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return l10n.automationPromptRequired;
                  }
                  if (v.length > 4000) return l10n.automationPromptTooLong;
                  return null;
                },
              ),
            ),
            if (_kind == AutomationFormKind.offPeak)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: context.zt.textLo,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l10n.automationOffPeakFormHint,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.zt.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            if (candidates.isNotEmpty)
              ZrField(
                label: l10n.automationFieldWorkspace,
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedWorkspace(candidates),
                  decoration: zrInputDecoration(context),
                  style: TextStyle(fontSize: 13, color: context.zt.textHi),
                  items: [
                    for (final candidate in _workspaceItems(candidates))
                      DropdownMenuItem(
                        value: candidate,
                        child: Text(
                          candidate,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _workspace = v),
                  validator: (v) =>
                      (v == null || v.isEmpty) ||
                          _selectedWorkspace(candidates) == null
                      ? l10n.automationWorkspaceRequired
                      : null,
                ),
              )
            else
              ZrField(
                label: l10n.automationFieldWorkspaceManual,
                child: TextFormField(
                  controller: _manualWorkspace,
                  style: zrMono(fontSize: 13, weight: FontWeight.w400),
                  decoration: zrInputDecoration(context),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? l10n.automationWorkspaceRequired
                      : null,
                ),
              ),
            const SizedBox(height: 16),
            Text(
              l10n.automationAdvanced,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.zt.textLo,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: context.zt.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.zt.hairline),
              ),
              child: Column(
                children: [
                  _advancedRow(
                    title: l10n.automationPermissionMode,
                    subtitle: l10n.advPermissionDesc,
                    trailing: DropdownButton<String>(
                      value: _permissionMode,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      // 收起态只显示标签（避免双行把行高撑爆），菜单里才带官方描述。
                      selectedItemBuilder: (context) => [
                        for (final mode in _permissionModeItems())
                          Builder(
                            builder: (context) => Text(
                              _permissionLabel(l10n, mode),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: context.zt.textHi,
                              ),
                            ),
                          ),
                      ],
                      items: [
                        for (final mode in _permissionModeItems())
                          DropdownMenuItem(
                            value: mode,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_permissionLabel(l10n, mode)),
                                Text(
                                  _permissionDesc(l10n, mode),
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: context.zt.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _permissionMode = v ?? 'build'),
                    ),
                  ),
                  _advancedRow(
                    title: l10n.automationFieldModel,
                    subtitle: l10n.advModelDesc,
                    trailing: _modelOptions.isEmpty
                        ? HwChip(text: _modelId)
                        : DropdownButton<String>(
                            value: _selectedModelKey,
                            underline: const SizedBox.shrink(),
                            isDense: true,
                            selectedItemBuilder: (context) => [
                              for (final o in _modelOptions)
                                Builder(
                                  builder: (context) => ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 150,
                                    ),
                                    child: Text(
                                      o.modelId,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: context.zt.textHi,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                            items: [
                              for (final o in _modelOptions)
                                DropdownMenuItem(
                                  value: o.key,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 220,
                                    ),
                                    child: Text(
                                      o.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              final picked = _modelOptions.firstWhere(
                                (o) => o.key == v,
                              );
                              setState(() {
                                _selectedModelKey = v;
                                _modelId = picked.modelId;
                                if (!picked.reasoningLevels.contains(
                                  _thoughtLevel,
                                )) {
                                  _thoughtLevel =
                                      picked.reasoningLevels.isNotEmpty
                                      ? picked.reasoningLevels.last
                                      : _thoughtLevel;
                                }
                              });
                            },
                          ),
                  ),
                  _advancedRow(
                    title: l10n.automationFieldThoughtLevel,
                    subtitle: l10n.advThoughtDesc,
                    trailing: (_modelOptions.isEmpty ||
                            (_pickedModel?.reasoningLevels.isEmpty ?? true))
                        ? HwChip(text: _thoughtLevel)
                        : DropdownButton<String>(
                            value: _pickedModel!.reasoningLevels.contains(
                                      _thoughtLevel,
                                    )
                                    ? _thoughtLevel
                                    : _pickedModel!.reasoningLevels.last,
                            underline: const SizedBox.shrink(),
                            isDense: true,
                            items: [
                              for (final lv in _pickedModel!.reasoningLevels)
                                DropdownMenuItem(
                                  value: lv,
                                  child: Text(_thoughtLabel(l10n, lv)),
                                ),
                            ],
                            onChanged: (v) =>
                                setState(() => _thoughtLevel = v ?? 'max'),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _presetChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final zt = context.zt;
    return Material(
      color: zt.surfaceHi,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: zt.hairlineBright),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: zt.textLo),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(fontSize: 11.5, color: zt.textHi),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _advancedRow({
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: context.zt.textHi,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 11.5, color: context.zt.textLo),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(child: trailing),
        ],
      ),
    );
  }

  List<String> _workspaceItems(List<String> candidates) {
    final selected = _selectedWorkspace(candidates);
    if (selected == null || candidates.contains(selected)) return candidates;
    return [selected, ...candidates];
  }

  List<String> _permissionModeItems() {
    if (kPermissionModes.contains(_permissionMode)) return kPermissionModes;
    return [_permissionMode, ...kPermissionModes];
  }

  List<Widget> _scheduleFields(AppLocalizations l10n) {
    return [
      ZrField(
        label: l10n.automationFieldSchedule,
        child: ZrSegmented(
          segments: [
            ('daily', l10n.automationCronDaily),
            ('weekdays', l10n.automationCronWeekdays),
            ('weekend', l10n.automationCronWeekend),
            ('custom', l10n.automationCronCustom),
          ],
          active: switch (_preset) {
            CronPreset.daily => 'daily',
            CronPreset.weekdays => 'weekdays',
            CronPreset.weekend => 'weekend',
            CronPreset.custom => 'custom',
          },
          onChanged: (value) => setState(() => _preset = switch (value) {
            'daily' => CronPreset.daily,
            'weekdays' => CronPreset.weekdays,
            'weekend' => CronPreset.weekend,
            _ => CronPreset.custom,
          }),
        ),
      ),
      const SizedBox(height: 12),
      if (_preset != CronPreset.custom) ...[
        _timePickerButton(l10n),
        const SizedBox(height: 10),
        ZrInterpreterBar(
          text: l10n.automationCronInterpreted(
            CronHumanizer.describe(_cronExpr, l10n),
          ),
        ),
      ],
      if (_preset == CronPreset.custom)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ZrField(
              label: 'CRON',
              child: TextFormField(
                controller: _cron,
                style: zrMono(fontSize: 13, weight: FontWeight.w400),
                decoration: zrInputDecoration(context, hint: 'm h dom mon dow'),
                validator: (v) => CronHumanizer.isValid(v ?? '')
                    ? null
                    : l10n.automationCronInvalid,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: 6),
            ZrInterpreterBar(
              text: l10n.automationCronInterpreted(
                CronHumanizer.describe(_cron.text, l10n),
              ),
            ),
          ],
        ),
      const SizedBox(height: 14),
    ];
  }

  Widget _timePickerButton(AppLocalizations l10n) {
    final zt = context.zt;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: _time,
        );
        if (picked != null) setState(() => _time = picked);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: zt.surfaceHi,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: zt.hairlineBright),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.schedule, size: 16, color: zt.accent),
            const SizedBox(width: 8),
            Text(
              _time.format(context),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: zt.textHi,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
