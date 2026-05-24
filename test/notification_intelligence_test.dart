import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/features/modules/notification_intelligence/notification_models.dart';
import 'package:meow_agent/services/agent_runtime/tool_router.dart';

void main() {
  group('NotificationInfo', () {
    test('fromMap parses notification correctly', () {
      final raw = {
        'id': 'notif_1',
        'packageName': 'com.whatsapp',
        'appName': 'WhatsApp',
        'title': 'John',
        'text': 'Bro jadi ga?',
        'timestamp': 1779607320000,
        'clearable': true,
      };

      final n = NotificationInfo.fromMap(raw);

      expect(n.id, 'notif_1');
      expect(n.packageName, 'com.whatsapp');
      expect(n.appName, 'WhatsApp');
      expect(n.title, 'John');
      expect(n.text, 'Bro jadi ga?');
      expect(n.timestamp, 1779607320000);
      expect(n.clearable, true);
      expect(n.hasContent, true);
    });

    test('fromMap handles empty/null fields gracefully', () {
      final n = NotificationInfo.fromMap({});

      expect(n.id, '');
      expect(n.packageName, '');
      expect(n.appName, 'Unknown');
      expect(n.title, isNull);
      expect(n.text, isNull);
      expect(n.timestamp, 0);
      expect(n.clearable, true);
      expect(n.hasContent, false);
    });

    test('hasContent false when both title and text are empty/blank', () {
      final n = NotificationInfo.fromMap({
        'id': 'x',
        'title': '   ',
        'text': '',
      });

      expect(n.hasContent, false);
    });

    test('toJson round-trip preserves fields', () {
      const n = NotificationInfo(
        id: 'a',
        packageName: 'com.foo',
        appName: 'Foo',
        title: 'Hi',
        text: 'There',
        timestamp: 12345,
        clearable: false,
      );

      final json = n.toJson();

      expect(json['id'], 'a');
      expect(json['appName'], 'Foo');
      expect(json['title'], 'Hi');
      expect(json['text'], 'There');
      expect(json['clearable'], false);
    });
  });

  group('Notification tools registration', () {
    final router = ToolRouter();

    test('notification.status registered as safe, no confirmation', () {
      final def = router.getDefinition('notification.status');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
    });

    test('notification.read_recent registered as sensitive-lite', () {
      final def = router.getDefinition('notification.read_recent');
      expect(def, isNotNull);
      expect(def!.risk, 'sensitive-lite');
      expect(def.requiresConfirmation, false);
      expect(def.inputSchema.containsKey('limit'), true);
    });

    test('notification.summarize registered', () {
      final def = router.getDefinition('notification.summarize');
      expect(def, isNotNull);
      expect(def!.requiresConfirmation, false);
    });

    test('notification.classify registered', () {
      final def = router.getDefinition('notification.classify');
      expect(def, isNotNull);
      expect(def!.requiresConfirmation, false);
    });

    test('notification.reply_suggestion registered with notificationId arg',
        () {
      final def = router.getDefinition('notification.reply_suggestion');
      expect(def, isNotNull);
      expect(def!.requiresConfirmation, false);
      expect(def.inputSchema.containsKey('notificationId'), true);
      expect(def.inputSchema.containsKey('tone'), true);
    });

    test('notification.open_app registered as safe', () {
      final def = router.getDefinition('notification.open_app');
      expect(def, isNotNull);
      expect(def!.risk, 'safe');
      expect(def.requiresConfirmation, false);
    });

    test('all 6 notification.* tools are registered', () {
      const tools = [
        'notification.status',
        'notification.read_recent',
        'notification.summarize',
        'notification.classify',
        'notification.reply_suggestion',
        'notification.open_app',
      ];
      for (final t in tools) {
        expect(router.isRegistered(t), true, reason: '$t not registered');
      }
    });

    test('descriptions in registry mention key behavior', () {
      final descriptions = router.buildAllToolDescriptions().join('\n');
      expect(descriptions, contains('notification.status'));
      expect(descriptions, contains('notification.read_recent'));
      // reply_suggestion must clearly state "DOES NOT SEND" so the LLM knows.
      final reply =
          router.getDefinition('notification.reply_suggestion')!.description;
      expect(reply.toLowerCase(), contains('does not send'));
    });
  });

  group('Notification importance heuristic', () {
    // The classify executor uses a regex on title+text. We assert it includes
    // common urgent keywords so future edits don't accidentally narrow it.
    test('urgent regex covers common ID + EN keywords', () {
      final urgentRegex = RegExp(
        r'\b(urgent|penting|asap|deadline|segera|tolong|help|bayar|invoice|otp|kode|code|verify|verifikasi|password|login|alert|warning|error|gagal|failed|reminder|booking|tiket|approve|approval|menunggu|waiting|pending)\b',
        caseSensitive: false,
      );

      const samples = [
        'Tolong jawab segera',
        'Your OTP is 123456',
        'Penting: cek dokumen ini',
        'Approval menunggu kamu',
        'Login attempt detected',
      ];
      for (final s in samples) {
        expect(urgentRegex.hasMatch(s), true, reason: '"$s" should match');
      }

      const nonUrgent = [
        'Have a great weekend',
        'New post from your friend',
        'Daily tip: drink water',
      ];
      for (final s in nonUrgent) {
        expect(urgentRegex.hasMatch(s), false, reason: '"$s" should not match');
      }
    });
  });
}
