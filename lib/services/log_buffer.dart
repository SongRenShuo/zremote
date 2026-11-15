import 'dart:collection';

import 'package:flutter/foundation.dart' show debugPrint;

/// 应用内诊断日志环形缓冲（P3-2）。
///
/// 捕获 debugPrint 流（main.dart 装配：包装 debugPrint，进缓冲 + 原样
/// 输出），供数据管理页导出分享。真机无 adb logcat 权限，导出是排障的
/// 唯一通道。日志落缓冲前统一脱敏（[redact]，S2 反向验证锚点）。
class LogBuffer {
  LogBuffer._();

  static final LogBuffer instance = LogBuffer._();

  /// 环形容量（条）；溢出丢最旧。
  static const int capacity = 800;

  final ListQueue<_LogLine> _lines = ListQueue();

  /// 脱敏命中行计数（导出摘要与测试旁证）。
  int redactedLines = 0;

  void add(String? message, {DateTime? at}) {
    if (message == null || message.isEmpty) return;
    final redacted = redact(message);
    if (redacted != message) {
      redactedLines++;
    }
    _lines.add(_LogLine(at ?? DateTime.now(), redacted));
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
  }

  /// 敏感值打码：authorization/token/sid 的值替换为 `***`。
  ///
  /// 匹配形态（大小写不敏感）：`key=value`、`key: value`、
  /// `"key":"value"`；authorization 额外吞「Bearer token」两段值。
  static String redact(String message) {
    var out = message;
    for (final pattern in _sensitivePatterns) {
      out = out.replaceAllMapped(pattern, (m) => '${m[1]}***');
    }
    return out;
  }

  /// 前缀字符类（注释供人读）：键前是词首（串首或非词字符，含 URL 查询
  /// 分隔 ? 与 &），防误伤 sessionId 等长词；分隔符=可选引号+冒号/等号；
  /// 值=连续段（在空白/,/;/"/'/&/? 截断）。三个正则分别对应
  /// authorization（值吞「Bearer token」两段）/token 族/sid。
  static final List<RegExp> _sensitivePatterns = [
    RegExp(
      r'''((?:^|[\s,{"'_?&-])authorization["']?\s*[=:]\s*["']?)[^\s,;"'&?]+(?:[ \t]+[^\s,;"'&?]+)?''',
      caseSensitive: false,
    ),
    RegExp(
      r'''((?:^|[\s,{"'_?&-])(?:access_token|refresh_token|token)["']?\s*[=:]\s*["']?)[^\s,;"'&?]+''',
      caseSensitive: false,
    ),
    RegExp(
      r'''((?:^|[\s,{"'_?&-])sid["']?\s*[=:]\s*["']?)[^\s,;"'&?]+''',
      caseSensitive: false,
    ),
  ];

  /// 导出全文（时间戳 + 行内容）。
  String dump() {
    final buf = StringBuffer();
    for (final l in _lines) {
      String two(int n) => n.toString().padLeft(2, '0');
      buf
        ..write(l.at.year.toString().padLeft(4, '0'))
        ..write('-')
        ..write(two(l.at.month))
        ..write('-')
        ..write(two(l.at.day))
        ..write(' ')
        ..write(two(l.at.hour))
        ..write(':')
        ..write(two(l.at.minute))
        ..write(':')
        ..write(two(l.at.second))
        ..write(' ')
        ..writeln(l.text);
    }
    return buf.toString();
  }

  int get length => _lines.length;

  void clear() {
    _lines.clear();
    redactedLines = 0;
  }

  static bool _installed = false;

  /// main.dart 装配入口：包装全局 debugPrint（应用侧日志进缓冲 + 原样
  /// 转发原实现）。幂等：重复装配不叠加包装。
  static void installDebugPrintCapture() {
    if (_installed) return;
    _installed = true;
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      LogBuffer.instance.add(message);
      original(message, wrapWidth: wrapWidth);
    };
  }

  /// 测试复位。
  static void debugResetInstall() => _installed = false;
}

class _LogLine {
  const _LogLine(this.at, this.text);

  final DateTime at;
  final String text;
}
