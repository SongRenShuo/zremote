import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/event_observer.dart';
import 'package:zremote/state/session_index.dart';

SessionState _s(
  String id, {
  String? title,
  String? phase,
  int perm = 0,
  int input = 0,
  String? workspace,
  bool pinned = false,
}) => SessionState(
  sessionId: id,
  title: title,
  phase: phase,
  permissionCount: perm,
  userInputCount: input,
  workspace: workspace,
  pinned: pinned,
);

void main() {
  group('SessionFilter.apply 纯函数矩阵（P4-3）', () {
    final sessions = [
      _s('a', title: '重构登录', phase: 'running', workspace: 'web-app'),
      _s('b', title: '修 BUG', phase: 'error', perm: 1),
      _s('c', title: '文档', phase: 'completedSuccess', input: 2),
      _s('d', phase: 'running', workspace: 'api-server'),
    ];

    test('空查询 + all = 原样全量', () {
      expect(SessionFilter.apply(sessions).length, 4);
    });

    test('搜索标题（不区分大小写）', () {
      final hit = SessionFilter.apply(sessions, query: '登录');
      expect(hit.length, 1);
      expect(hit.first.sessionId, 'a');
      expect(SessionFilter.apply(sessions, query: 'BUG').first.sessionId, 'b');
    });

    test('搜索工作区与 sessionId', () {
      expect(
        SessionFilter.apply(sessions, query: 'api').single.sessionId,
        'd',
      );
      expect(SessionFilter.apply(sessions, query: 'c').map((s) => s.sessionId),
          contains('c'));
    });

    test('状态过滤：running', () {
      final running = SessionFilter.apply(
        sessions,
        kind: SessionFilterKind.running,
      );
      expect(running.map((s) => s.sessionId), ['a', 'd']);
    });

    test('状态过滤：needsInput（perm 或 input > 0）', () {
      final need = SessionFilter.apply(
        sessions,
        kind: SessionFilterKind.needsInput,
      );
      expect(need.map((s) => s.sessionId), ['b', 'c']);
    });

    test('搜索 × 状态组合交集', () {
      final both = SessionFilter.apply(
        sessions,
        query: '修',
        kind: SessionFilterKind.needsInput,
      );
      expect(both.single.sessionId, 'b');
      expect(
        SessionFilter.apply(
          sessions,
          query: '修',
          kind: SessionFilterKind.running,
        ),
        isEmpty,
      );
    });
  });

  group('pinnedFirst（置顶优先，组内保序）', () {
    test('pinned 全部前置，未置顶保持相对顺序', () {
      final list = [
        _s('a', pinned: false),
        _s('b', pinned: true),
        _s('c', pinned: false),
        _s('d', pinned: true),
      ];
      final out = SessionFilter.pinnedFirst(list);
      expect(out.map((s) => s.sessionId), ['b', 'd', 'a', 'c']);
    });

    test('无置顶 = 原序', () {
      final list = [_s('a'), _s('b')];
      expect(SessionFilter.pinnedFirst(list).map((s) => s.sessionId),
          ['a', 'b']);
    });
  });

  group('SessionJumpRequestNotifier（P4-7）', () {
    test('seq 自增：同一会话连续两次请求都触发状态变化', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(sessionJumpRequestProvider.notifier);
      notifier.request('d1', 't1');
      final first = container.read(sessionJumpRequestProvider)!;
      expect(first.deviceId, 'd1');
      expect(first.sessionId, 't1');
      notifier.request('d1', 't1');
      final second = container.read(sessionJumpRequestProvider)!;
      expect(second.seq, greaterThan(first.seq));
    });

    test('初始 null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(sessionJumpRequestProvider), isNull);
    });
  });
}
