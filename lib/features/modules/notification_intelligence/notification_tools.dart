import 'package:flutter/services.dart';

import '../../../services/agent_runtime/runtime_models.dart';
import '../data/module_repository.dart';
import 'agent_notification_service.dart';
import 'notification_repository.dart';
import 'notification_service.dart';

class NotificationTools {
  NotificationTools({required this.moduleRepository});

  final ModuleRepository moduleRepository;

  NotificationRepository _repo() => NotificationRepository(
    service: NotificationService(),
    moduleRepository: moduleRepository,
  );

  Future<ToolExecutionResult> executeStatus() async {
    try {
      final res = await _repo().getStatus();
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.status',
          error: res.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.status',
        data: {
          'granted': res.granted,
          'hint': res.granted
              ? null
              : 'User must enable Notification access in Android Settings.',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.status',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeReadRecent(
    Map<String, dynamic> args,
  ) async {
    try {
      final limit = (args['limit'] as num?)?.toInt() ?? 10;
      final res = await _repo().getRecent(limit: limit);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.read_recent',
          error: res.error,
        );
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.read_recent',
        data: {
          'count': res.data!.length,
          'notifications': res.data!.map((n) => n.toJson()).toList(),
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.read_recent',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeSummarize(
    Map<String, dynamic> args,
  ) async {
    try {
      final limit = (args['limit'] as num?)?.toInt() ?? 25;
      final res = await _repo().getForSummary(limit: limit);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.summarize',
          error: res.error,
        );
      }
      final byApp = <String, int>{};
      for (final n in res.data!) {
        byApp[n.appName] = (byApp[n.appName] ?? 0) + 1;
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.summarize',
        data: {
          'count': res.data!.length,
          'byApp': byApp,
          'notifications': res.data!.map((n) => n.toJson()).toList(),
          'hint':
              'Summarize naturally in Indonesian. Group by app. Mention notable senders/titles.',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.summarize',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeClassify(Map<String, dynamic> args) async {
    try {
      final limit = (args['limit'] as num?)?.toInt() ?? 15;
      final res = await _repo().getForClassify(limit: limit);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.classify',
          error: res.error,
        );
      }
      final urgentRegex = RegExp(
        r'\b(urgent|penting|asap|deadline|segera|tolong|help|bayar|invoice|otp|kode|code|verify|verifikasi|password|login|alert|warning|error|gagal|failed|reminder|booking|tiket|approve|approval|menunggu|waiting|pending)\b',
        caseSensitive: false,
      );
      final flagged = <Map<String, dynamic>>[];
      for (final n in res.data!) {
        final haystack = '${n.title ?? ''} ${n.text ?? ''}';
        if (urgentRegex.hasMatch(haystack)) {
          flagged.add({
            'id': n.id,
            'appName': n.appName,
            'title': n.title,
            'text': n.text,
            'reason': 'matched urgent keyword',
          });
        }
      }
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.classify',
        data: {
          'totalScanned': res.data!.length,
          'flagged': flagged,
          'all': res.data!.map((n) => n.toJson()).toList(),
          'hint':
              'Use the flagged list as starting point; re-rank with judgment. Reply naturally in Indonesian.',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.classify',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeReplySuggestion(
    Map<String, dynamic> args,
  ) async {
    try {
      final id = (args['notificationId'] as String?)?.trim() ?? '';
      final tone = (args['tone'] as String?)?.trim().toLowerCase() ?? 'casual';
      if (id.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notification.reply_suggestion',
          error: 'Missing required arg: notificationId',
        );
      }
      final res = await _repo().getForReply(id);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.reply_suggestion',
          error: res.error,
        );
      }
      final n = res.data!;
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.reply_suggestion',
        data: {
          'source': n.toJson(),
          'tone': tone,
          'hint':
              'Generate ONE short reply suggestion in Indonesian (or matching the source language) with $tone tone. '
              'DO NOT actually send. The user will copy the reply manually. '
              'Reply field key: "suggestion".',
        },
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.reply_suggestion',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeOpenApp(Map<String, dynamic> args) async {
    try {
      final id = (args['notificationId'] as String?)?.trim() ?? '';
      if (id.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notification.open_app',
          error: 'Missing required arg: notificationId',
        );
      }
      final res = await _repo().getForOpenApp(id);
      if (res.error != null) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.open_app',
          error: res.error,
        );
      }
      final pkg = res.data!.packageName;
      const channel = MethodChannel('com.meowagent/app_control');
      final success =
          await channel.invokeMethod<bool>('openApp', {'package': pkg}) ??
          false;
      return ToolExecutionResult(
        success: success,
        toolName: 'notification.open_app',
        data: {'package': pkg, 'appName': res.data!.appName, 'opened': success},
        error: success ? null : 'Failed to open app: $pkg',
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.open_app',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeCreateLocal(
    Map<String, dynamic> args,
  ) async {
    try {
      final title = (args['title'] ?? '').toString().trim();
      final body = (args['body'] ?? '').toString().trim();
      if (title.isEmpty || body.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notification.create_local',
          error: 'title and body are required.',
        );
      }
      final styleRaw = (args['style'] ?? 'normal').toString().toLowerCase();
      final style =
          (styleRaw == 'silent' || styleRaw == 'normal' || styleRaw == 'alarm')
          ? styleRaw
          : 'normal';
      final id = await AgentNotificationService.showNow(
        title: title,
        body: body,
        style: style,
      );
      return ToolExecutionResult(
        success: true,
        toolName: 'notification.create_local',
        data: {'notificationId': id, 'title': title, 'style': style},
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.create_local',
        error: e.toString(),
      );
    }
  }

  Future<ToolExecutionResult> executeReply(Map<String, dynamic> args) async {
    try {
      final notifId = (args['notificationId'] as String?)?.trim() ?? '';
      final message = (args['message'] as String?)?.trim() ?? '';

      if (notifId.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notification.reply',
          error: 'Missing required arg: notificationId',
        );
      }
      if (message.isEmpty) {
        return const ToolExecutionResult(
          success: false,
          toolName: 'notification.reply',
          error: 'Missing required arg: message',
        );
      }

      // Check if notification supports reply.
      final service = NotificationService();
      final canReply = await service.hasReplyAction(notifId);
      if (!canReply) {
        return ToolExecutionResult(
          success: false,
          toolName: 'notification.reply',
          error:
              'Notification does not support direct reply (no RemoteInput action). '
              'The notification may have been dismissed or the app does not support inline replies.',
        );
      }

      // Send the reply.
      final result = await service.replyToNotification(
        notifId: notifId,
        message: message,
      );

      final success = result['success'] == true;
      return ToolExecutionResult(
        success: success,
        toolName: 'notification.reply',
        data: {
          'notificationId': notifId,
          'messageSent': success ? message : null,
          'error': result['error'],
        },
        error: success ? null : (result['error'] as String? ?? 'reply_failed'),
      );
    } catch (e) {
      return ToolExecutionResult(
        success: false,
        toolName: 'notification.reply',
        error: e.toString(),
      );
    }
  }
}
