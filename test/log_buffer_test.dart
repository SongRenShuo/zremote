import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/services/log_buffer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LogBuffer.instance.clear();
    LogBuffer.debugResetInstall();
  });

  group('脱敏（S2 锚点：authorization/token/sid 值打码）', () {
    test('authorization: Bearer 两段值整体打码', () {
      expect(
        LogBuffer.redact('authorization: Bearer eyJhbGciOi.abc123'),
        'authorization: ***',
      );
      expect(
        LogBuffer.redact('Authorization=tok_9f8e7d'),
        'Authorization=***',
      );
    });

    test('"authorization":"value" JSON 形态', () {
      final out = LogBuffer.redact('{"authorization":"jwt-secret"}');
      expect(out, '{"authorization":"***"}');
      expect(out.contains('jwt-secret'), isFalse);
    });

    test('token= / "token": 形态与 access_token/refresh_token', () {
      expect(LogBuffer.redact('token=abcdef123'), 'token=***');
      expect(
        LogBuffer.redact('"access_token":"at-xyz"'),
        '"access_token":"***"',
      );
      expect(
        LogBuffer.redact('refresh_token: rt-42'),
        'refresh_token: ***',
      );
    });

    test('sid= / "sid":"..." 形态（URL 查询串）', () {
      expect(
        LogBuffer.redact('https://zcode.z.ai/remote/v4?sid=s3cr3t&hash=h'),
        'https://zcode.z.ai/remote/v4?sid=***&hash=h',
      );
      expect(LogBuffer.redact('"sid":"abc"'), '"sid":"***"');
    });

    test('非键形态不误伤：sessionId / considered / 普通句子', () {
      expect(LogBuffer.redact('sessionId=task_1'), 'sessionId=task_1');
      expect(LogBuffer.redact('considered=done'), 'considered=done');
      expect(
        LogBuffer.redact('the token is not present here'),
        'the token is not present here',
      );
      expect(LogBuffer.redact('[zr-resume] ws closed r=2'), '[zr-resume] ws closed r=2');
    });
  });

  group('环形缓冲', () {
    test('容量裁旧（超容量丢最旧）', () {
      for (var i = 0; i < LogBuffer.capacity + 50; i++) {
        LogBuffer.instance.add('line $i');
      }
      expect(LogBuffer.instance.length, LogBuffer.capacity);
      final dump = LogBuffer.instance.dump();
      expect(dump.contains('line 0\n'), isFalse, reason: '最旧被裁');
      expect(dump.contains('line ${LogBuffer.capacity + 49}'), isTrue);
    });

    test('dump 带时间戳行；命中脱敏行计数', () {
      LogBuffer.instance.add('sid=secret1');
      LogBuffer.instance.add('plain line');
      expect(LogBuffer.instance.redactedLines, 1);
      final dump = LogBuffer.instance.dump();
      expect(dump.contains('sid=***'), isTrue);
      expect(dump.contains('secret1'), isFalse);
      expect(dump.contains('plain line'), isTrue);
      // 时间戳形态 2026-11-15 12:34:56
      expect(RegExp(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ').hasMatch(dump),
          isTrue);
    });

    test('空消息不入缓冲；clear 复位计数', () {
      LogBuffer.instance.add(null);
      LogBuffer.instance.add('');
      expect(LogBuffer.instance.length, 0);
      LogBuffer.instance.add('sid=x');
      LogBuffer.instance.clear();
      expect(LogBuffer.instance.length, 0);
      expect(LogBuffer.instance.redactedLines, 0);
    });
  });
}
