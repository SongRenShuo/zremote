import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 设置页「连接诊断」入口（P3-7）：诊断页需要活的 RpcBridge，只有
/// SessionView 持有；设置页发请求，active 的 SessionView 消费并打开
/// DiagnosticsPage。seq 自增保证重复请求都触发。
class DiagnosticsOpenRequestNotifier
    extends Notifier<({String deviceId, int seq})?> {
  int _seq = 0;

  @override
  ({String deviceId, int seq})? build() => null;

  void request(String deviceId) {
    _seq++;
    state = (deviceId: deviceId, seq: _seq);
  }
}

final diagnosticsOpenRequestProvider =
    NotifierProvider<DiagnosticsOpenRequestNotifier,
        ({String deviceId, int seq})?>(DiagnosticsOpenRequestNotifier.new);
