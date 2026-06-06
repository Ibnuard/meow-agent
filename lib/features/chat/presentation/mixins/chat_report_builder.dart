import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_history_service.dart';
import '../../data/chat_runtime_log_service.dart';
import '../../../../services/agent_runtime/context_compactor.dart';
import '../../../../services/agent_runtime/context_report.dart';
import '../../../../services/llm/openai_compatible_client.dart';
import '../../../settings/data/app_language_provider.dart';
import '../../../settings/data/llm_debug_provider.dart';
import '../../../providers/data/provider_repository.dart';
import '../../../agents/data/agent_repository.dart';

/// Report building utilities (status, context, logs).
mixin ChatReportBuilderMixin<T extends StatefulWidget> on State<T> {
  AppStrings get s;
  String get activeAgentId;
  List<ChatMessage> get messagesList;
  TextEditingController get inputController;
  WidgetRef get ref;

  Future<String> buildRuntimeLogReport() async {
    if (!ref.read(llmDebugModeProvider)) {
      return s.debugOffForLog;
    }

    final events = await ref
        .read(chatRuntimeLogServiceProvider)
        .loadLast(activeAgentId);
    if (events.isEmpty) {
      return s.noRuntimeLog;
    }

    String? userMessage;
    final stepEvents = <ChatRuntimeLogEvent>[];
    for (final event in events) {
      if (event.isUserRequest) {
        userMessage = event.data?['message']?.toString();
      } else {
        stepEvents.add(event);
      }
    }

    final buffer = StringBuffer(s.runtimeLogHeader);
    if (userMessage != null && userMessage.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Command: ${truncateLogText(userMessage, 220)}');
    }

    if (stepEvents.isEmpty) {
      buffer
        ..writeln()
        ..write(s.noRuntimeSteps);
      return buffer.toString();
    }

    for (var i = 0; i < stepEvents.length; i++) {
      final event = stepEvents[i];
      buffer
        ..writeln()
        ..write('${i + 1}. ${formatRuntimeLogLine(event)}');
      final details = formatRuntimeLogDetails(event);
      if (details.isNotEmpty) {
        buffer
          ..writeln()
          ..write('   $details');
      }
    }

    return buffer.toString();
  }

  Future<String> clearRuntimeLog() async {
    if (!ref.read(llmDebugModeProvider)) {
      return s.debugOffForClearlog;
    }

    await ref.read(chatRuntimeLogServiceProvider).clear(activeAgentId);
    return s.runtimeLogCleared;
  }

  String formatRuntimeLogLine(ChatRuntimeLogEvent event) {
    final label = switch (event.type) {
      'state_change' => event.data?['state']?.toString() ?? 'state',
      'llm_decision' => 'llm',
      'tool_call' => 'tool call',
      'tool_result' => 'tool result',
      'narrative' => 'narrative',
      'error' => 'error',
      'confirmation' => 'confirmation',
      'cancelled' => 'cancelled',
      _ => event.type,
    };
    return '[$label] ${truncateLogText(event.message, 260)}';
  }

  String formatRuntimeLogDetails(ChatRuntimeLogEvent event) {
    final data = event.data;
    if (data == null || data.isEmpty) return '';

    switch (event.type) {
      case 'state_change':
        return '';
      case 'tool_call':
        return compactLogJson({
          'tool': data['name'],
          'args': data['args'],
          'risk': data['risk'],
        });
      case 'tool_result':
        final details = <String, dynamic>{
          'tool': data['tool'],
          'success': data['success'],
        };
        if (data['error'] != null) {
          details['error'] = data['error'];
        }
        if (data['data'] != null) {
          details['data'] = data['data'];
        }
        return compactLogJson(details);
      case 'error':
        return truncateLogText(data['error']?.toString() ?? '', 700);
      default:
        return compactLogJson(data);
    }
  }

  String compactLogJson(Object? value, {int maxChars = 700}) {
    if (value == null) return '';
    try {
      return truncateLogText(jsonEncode(value), maxChars);
    } catch (_) {
      return truncateLogText(value.toString(), maxChars);
    }
  }

  String truncateLogText(String text, int maxChars) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= maxChars) return compact;
    return '${compact.substring(0, maxChars)}...';
  }

  Future<String> buildContextReport() async {
    final agents = ref.read(agentListProvider);
    final agent = activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == activeAgentId).firstOrNull;
    if (agent == null) {
      return s.noActiveAgent;
    }

    final languagePref = ref.read(appLanguageProvider);
    final languageCode = resolveLanguageCode(languagePref);
    return ContextReport.build(
      agentName: agent.name,
      languageCode: languageCode,
      messages: messagesList,
      maxContextLength: agent.maxContextLength,
      userMessageHint: inputController.text,
    );
  }

  /// Build /status info string.
  String buildStatusInfo() {
    final agents = ref.read(agentListProvider);
    final providers = ref.read(providerListProvider).value ?? [];
    final agent = activeAgentId == 'default'
        ? (agents.isNotEmpty ? agents.first : null)
        : agents.where((a) => a.id == activeAgentId).firstOrNull;
    final provider = agent != null
        ? providers.where((p) => p.id == agent.providerId).firstOrNull
        : null;

    final maxCtx = agent?.maxContextLength ?? 8191;
    final usage = ContextCompactor.getUsageInfo(
      messages: messagesList,
      maxContextLength: maxCtx,
    );

    final pct = usage.percentage.toStringAsFixed(1);
    final compactNote = usage.needsCompact
        ? s.autoCompactThresholdNote
        : s.autoCompactOkNote;

    // Cumulative token usage from all LLM calls this session.
    final records = OpenAiCompatibleClient.usageRecords;
    var totalInput = 0;
    var totalOutput = 0;
    for (final r in records) {
      totalInput += r.inputTokens;
      totalOutput += r.outputTokens ?? 0;
    }
    final totalTokens = totalInput + totalOutput;
    final totalCalls = records.length;

    final agentName = agent?.name ?? 'default';
    final providerName = provider?.nickname ?? '-';
    final providerModel = provider?.model ?? '-';

    final buf = StringBuffer()
      ..writeln(s.statusAgentTitle(agentName))
      ..writeln()
      ..writeln(s.statusConnected(providerName, providerModel))
      ..writeln()
      ..writeln(s.statusDetails)
      ..writeln()
      ..writeln('- ${s.statusApp}')
      ..writeln('- ${s.statusActiveAgent(agentName)}')
      ..writeln('- ${s.statusProvider(providerName)}')
      ..writeln('- ${s.statusModel(providerModel)}')
      ..writeln('- ${s.statusMessages(messagesList.length)}')
      ..writeln()
      ..writeln('Token Usage (session):')
      ..writeln()
      ..writeln('- Total: $totalTokens tokens ($totalCalls LLM calls)')
      ..writeln('- Input: $totalInput tokens')
      ..writeln('- Output: $totalOutput tokens')
      ..writeln('- Context pressure: ${usage.estimated}/$maxCtx ($pct%)')
      ..writeln()
      ..writeln(compactNote);

    return buf.toString().trim();
  }
}
