import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/event_observer.dart';
import '../state/session_index.dart';
import '../theme.dart';
import 'haptics.dart';
import 'motion.dart';

/// 会话面板（P4-3 搜索与过滤）：搜索框 + 状态 chip 纯本地过滤，
/// 过滤逻辑在 [SessionFilter] 纯函数（可单测），本组件只管装配。
class SessionPanelSheet extends StatefulWidget {
  const SessionPanelSheet({
    super.key,
    required this.sessions,
    this.activeSessionId,
    this.onSessionTap,
    this.onStopSession,
    this.deviceName,
    this.onClose,
    this.now,
  });

  final List<SessionState> sessions;

  final String? activeSessionId;

  final ValueChanged<String>? onSessionTap;

  /// P1-4：行内「停止」回调（仅 running 会话渲染按钮）。
  final ValueChanged<String>? onStopSession;

  final String? deviceName;

  final VoidCallback? onClose;

  final DateTime? now;

  static (String, Color)? phaseL10n(
    AppLocalizations l10n,
    String? phase,
    ZTPalette zt,
  ) => switch (phase) {
    'running' || 'prewarming' => (l10n.sessionPhaseRunning, zt.live),
    'completedSuccess' ||
    'completedInterrupted' => (l10n.sessionPhaseCompleted, zt.textLo),
    'error' => (l10n.sessionPhaseFailed, zt.danger),
    _ => null,
  };

  static String groupLabel(AppLocalizations l10n, String key) {
    if (key == 'pinned') return l10n.sessionGroupPinned;
    if (key == 'today') return l10n.sessionGroupToday;
    if (key == 'yesterday') return l10n.sessionGroupYesterday;
    if (key == 'thisWeek') return l10n.sessionGroupThisWeek;
    if (key == 'lastWeek') return l10n.sessionGroupLastWeek;
    if (key == 'thisMonth') return l10n.sessionGroupThisMonth;
    if (key == 'lastMonth') return l10n.sessionGroupLastMonth;
    if (key == 'older') return l10n.sessionGroupOlder;
    if (key == 'unknown') return l10n.sessionGroupOlder;
    if (key.startsWith('day:')) {
      return l10n.sessionGroupDays(int.tryParse(key.substring(4)) ?? 0);
    }
    return l10n.sessionGroupOlder;
  }

  @override
  State<SessionPanelSheet> createState() => _SessionPanelSheetState();
}

class _SessionPanelSheetState extends State<SessionPanelSheet> {
  final TextEditingController _search = TextEditingController();

  SessionFilterKind _kind = SessionFilterKind.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final effectiveNow = widget.now ?? DateTime.now();
    final visible = SessionFilter.pinnedFirst(
      SessionFilter.apply(widget.sessions, query: _search.text, kind: _kind),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: context.zt.hairline, width: 0.8),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.sessionsPanelTitle,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        color: context.zt.textHi,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.deviceName == null
                          ? l10n.sessionsPanelCount(visible.length)
                          : l10n.sessionsPanelSubtitle(
                              widget.deviceName!,
                              visible.length,
                            ),
                      style: TextStyle(
                        fontSize: 11,
                        color: context.zt.textLo,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.onClose != null)
                Tooltip(
                  message: AppLocalizations.of(context)!.commonCancel,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onClose,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white.withValues(alpha: 0.05)
                            : context.zt.surfaceHover,
                        border: Border.all(
                          color:
                              Theme.of(context).brightness == Brightness.dark
                              ? Colors.white.withValues(alpha: 0.08)
                              : context.zt.hairline,
                          width: 0.8,
                        ),
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: context.zt.textLo,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // P4-3：搜索框 + 状态过滤 chip（纯本地过滤，零 RPC）。
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: SizedBox(
            height: 36,
            child: TextField(
              key: const Key('session-panel-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: l10n.uxSessionSearchHint,
                prefixIcon: Icon(Icons.search, size: 17, color: context.zt.textLo),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
          child: SizedBox(
            height: 30,
            child: Row(
              children: [
                for (final (kind, label) in [
                  (SessionFilterKind.all, l10n.uxSessionFilterAll),
                  (SessionFilterKind.running, l10n.uxSessionFilterRunning),
                  (SessionFilterKind.needsInput, l10n.uxSessionFilterNeedsInput),
                ]) ...[
                  _FilterChip(
                    label: label,
                    selected: _kind == kind,
                    onTap: () {
                      ZrHaptics.tap();
                      setState(() => _kind = kind);
                    },
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ),
        if (widget.sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Text(
              l10n.sessionsPanelEmpty,
              style: TextStyle(fontSize: 13, color: context.zt.textLo),
            ),
          )
        else if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Text(
              l10n.uxSessionNoMatch,
              style: TextStyle(fontSize: 13, color: context.zt.textLo),
            ),
          )
        else
          Flexible(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                for (final group in SessionGrouping.groupByDay(
                  visible,
                  effectiveNow,
                  weekStartsMonday: l10n.localeName.startsWith('zh'),
                )) ...[
                  _GroupHeader(
                    label: SessionPanelSheet.groupLabel(l10n, group.key),
                    count: group.value.length,
                  ),
                  for (final s in group.value)
                    _SessionRow(
                      session: s,
                      active: widget.activeSessionId == s.sessionId,
                      now: effectiveNow,
                      onTap: widget.onSessionTap,
                      onStop: widget.onStopSession,
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: AnimatedContainer(
          duration: ZrMotion.duration(160),
          curve: ZrMotion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? zt.accentSubtle : zt.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? zt.accentBorder : zt.hairline,
              width: 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? zt.accent : zt.textLo,
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: zt.textTertiary,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: zrMono(fontSize: 10, weight: FontWeight.w400, color: zt.textLo),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.active,
    required this.now,
    this.onTap,
    this.onStop,
  });

  final SessionState session;
  final bool active;
  final DateTime now;
  final ValueChanged<String>? onTap;

  /// P1-4：停止生成回调；非 null 且会话 running 时渲染行内停止按钮。
  final ValueChanged<String>? onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = session;
    final title = (s.title == null || s.title!.isEmpty)
        ? s.sessionId
        : s.title!;
    final pill = SessionPanelSheet.phaseL10n(l10n, s.phase, context.zt);
    return InkWell(
      onTap: () => onTap?.call(s.sessionId),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: active
              ? context.zt.accentSubtle
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: active
              ? Border.all(color: context.zt.accentBorder)
              : Border.all(color: Colors.transparent),
        ),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Row(
          children: [
            Container(
              key: Key('session-active-dot-${s.sessionId}'),
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? context.zt.accent : Colors.transparent,
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: context.zt.accent.withValues(alpha: 0.6),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
            ),
            if (s.pinned) ...[
              Icon(
                Icons.push_pin_rounded,
                size: 12,
                color: context.zt.textTertiary,
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? context.zt.accent
                          : context.zt.textHi,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (s.workspace != null) ...[
                        Flexible(
                          child: Text(
                            s.workspace!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: context.zt.textLo,
                            ),
                          ),
                        ),
                        Text(
                          ' · ',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.zt.textLo,
                          ),
                        ),
                      ],
                      Flexible(
                        child: Text(
                          _relativeLabel(l10n),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.zt.textLo,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (s.permissionCount > 0) ...[
                  _CountPill(count: s.permissionCount, alert: true),
                  if (s.userInputCount > 0) const SizedBox(width: 6),
                ],
                if (s.userInputCount > 0) _CountPill(count: s.userInputCount),
                if (pill != null) ...[
                  const SizedBox(width: 6),
                  _PhasePill(label: pill.$1, color: pill.$2),
                ],
                // P1-4：running 会话行内「停止」按钮（stopGeneration）。
                if (onStop != null && s.phase == 'running') ...[
                  const SizedBox(width: 6),
                  _StopButton(onTap: () => onStop!(s.sessionId)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _relativeLabel(AppLocalizations l10n) {
    final t = RelativeTime.format(
      session.lastActivityAt,
      now.millisecondsSinceEpoch,
    );
    return switch (t.kind) {
      'minute' => l10n.sessionTimeMinutes(t.n),
      'hour' => l10n.sessionTimeHours(t.n),
      'day' => l10n.sessionTimeDays(t.n),
      _ => l10n.sessionTimeNow,
    };
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count, this.alert = false});

  final int count;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    if (alert) {
      return Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: context.zt.danger,
          boxShadow: [
            BoxShadow(
              color: context.zt.danger.withValues(alpha: 0.35),
              blurRadius: 4,
              spreadRadius: 0.5,
            ),
          ],
        ),
        child: Text(
          count >= 99 ? '99' : '$count',
          style: zrMono(
            fontSize: 10,
            weight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      );
    }
    final base = context.zt.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: base.withValues(alpha: 0.30)),
      ),
      child: Text(
        count >= 99 ? '99+' : '$count',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: base,
        ),
      ),
    );
  }
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zt = context.zt;
    return Tooltip(
      message: AppLocalizations.of(context)!.approvalStopTooltip,
      child: InkWell(
        key: const Key('session-stop-button'),
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: zt.danger.withValues(alpha: 0.12),
            border: Border.all(color: zt.danger.withValues(alpha: 0.4)),
          ),
          child: Icon(
            Icons.stop_rounded,
            size: 14,
            color: zt.danger,
          ),
        ),
      ),
    );
  }
}

class _PhasePill extends StatelessWidget {
  const _PhasePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Text(
        label,
        key: Key('session-phase-pill-$label'),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
