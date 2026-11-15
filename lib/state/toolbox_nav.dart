import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 设置页「连接诊断」入口（P3-7）：诊断页需要活的 RpcBridge，只有
/// SessionView 持有；设置页发请求，active 的 SessionView 消费并打开
/// DiagnosticsPage。seq 自增保证重复请求都触发。
///
/// 调用顺序是契约：设置页必须先 `Navigator.pop()` 再 `request()`。
/// Riverpod 的 `ref.listen` 同步派发，若先 request，SessionView 会立刻
/// push 诊断页，随后的 pop 弹掉的正是诊断页（设置页留在原地 = 点击无反应）。
class DiagnosticsOpenRequestNotifier
    extends Notifier<({String deviceId, int seq})?> {
  int _seq = 0;

  @override
  ({String deviceId, int seq})? build() => null;

  /// 发请求，返回本次 seq（供调用方判断是否已被消费）。
  int request(String deviceId) {
    _seq++;
    state = (deviceId: deviceId, seq: _seq);
    return _seq;
  }

  /// 消费者命中后清空，避免残留请求被后续监听者重复消费。
  void consume() => state = null;

  /// 本次请求是否仍未被消费者取走（无消费者时设置页给提示）。
  bool isPending(int seq) {
    final current = state;
    return current != null && current.seq == seq;
  }
}

final diagnosticsOpenRequestProvider =
    NotifierProvider<DiagnosticsOpenRequestNotifier,
        ({String deviceId, int seq})?>(DiagnosticsOpenRequestNotifier.new);
