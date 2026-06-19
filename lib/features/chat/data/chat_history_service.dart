import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../services/agent_runtime/runtime_models.dart';
import 'chat_session_service.dart';

/// Page size for initial latest-message load (fast, lightweight).
/// Older messages load at 30 per page when scrolling up.
const int kMessagePageSize = 30;

/// Persists chat messages per agent using SQLite with pagination support.
class ChatHistoryService {
  ChatHistoryService({String Function(String agentId)? sessionIdResolver})
    : _sessionIdResolver = sessionIdResolver;

  /// Resolves the current session id for an agent. Used to auto-tag writes
  /// that don't carry an explicit session, so callers across the app don't
  /// each have to thread the session id through.
  final String Function(String agentId)? _sessionIdResolver;

  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbDir = await getDatabasesPath();
    final dbPath = '$dbDir/meow_chat.db';
    return openDatabase(
      dbPath,
      version: 6,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            actions TEXT,
            image_paths TEXT,
            client_id TEXT,
            delivery_status TEXT NOT NULL DEFAULT 'sent',
            error_message TEXT,
            session_id TEXT,
            message_kind TEXT NOT NULL DEFAULT 'conversation',
            run_id TEXT,
            phase TEXT,
            evidence_refs TEXT,
            context_policy TEXT NOT NULL DEFAULT 'include'
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_messages_agent ON messages(agent_id)
        ''');
        await db.execute('''
          CREATE INDEX idx_messages_agent_id ON messages(agent_id, id)
        ''');
        await db.execute('''
          CREATE INDEX idx_messages_client_id ON messages(client_id)
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE messages ADD COLUMN actions TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE messages ADD COLUMN image_paths TEXT');
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE messages ADD COLUMN client_id TEXT');
          await db.execute(
            "ALTER TABLE messages ADD COLUMN delivery_status TEXT NOT NULL DEFAULT 'sent'",
          );
          await db.execute(
            'ALTER TABLE messages ADD COLUMN error_message TEXT',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_agent_id ON messages(agent_id, id)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_messages_client_id ON messages(client_id)',
          );
        }
        if (oldVersion < 5) {
          // Session id partitions LLM context. Existing messages are folded
          // into one legacy session so old history keeps loading as a single
          // continuous context until the user starts a fresh session.
          await db.execute('ALTER TABLE messages ADD COLUMN session_id TEXT');
          await db.execute(
            "UPDATE messages SET session_id = 'legacy' WHERE session_id IS NULL",
          );
        }
        if (oldVersion < 6) {
          await db.execute(
            "ALTER TABLE messages ADD COLUMN message_kind TEXT NOT NULL DEFAULT 'conversation'",
          );
          await db.execute('ALTER TABLE messages ADD COLUMN run_id TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN phase TEXT');
          await db.execute(
            'ALTER TABLE messages ADD COLUMN evidence_refs TEXT',
          );
          await db.execute(
            "ALTER TABLE messages ADD COLUMN context_policy TEXT NOT NULL DEFAULT 'include'",
          );
        }
      },
    );
  }

  /// Load the latest [limit] messages for an agent (most recent page).
  ///
  /// When [sessionId] is provided, only messages belonging to that session are
  /// returned. The chat UI calls this WITHOUT a session filter (it shows the
  /// full transcript across sessions), while the runtime calls it WITH the
  /// active session id so the LLM context stays isolated per session.
  Future<List<ChatMessage>> loadLatest(
    String agentId, {
    int limit = kMessagePageSize,
    String? sessionId,
  }) async {
    final db = await _database;
    // Get the latest N messages by ordering DESC then reversing.
    final rows = await db.query(
      'messages',
      where: sessionId == null
          ? 'agent_id = ?'
          : 'agent_id = ? AND session_id = ?',
      whereArgs: sessionId == null ? [agentId] : [agentId, sessionId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.map((r) => ChatMessage.fromRow(r)).toList();
  }

  /// Distinct session ids for an agent, most-recent first, each paired with the
  /// timestamp and a short preview of its first user message. Used by
  /// `/resume` discovery and session pickers.
  Future<List<ChatSessionInfo>> listSessions(String agentId) async {
    final db = await _database;
    final rows = await db.rawQuery(
      '''
      SELECT session_id,
             MIN(id) AS first_id,
             MAX(timestamp) AS last_ts,
             COUNT(*) AS msg_count
      FROM messages
      WHERE agent_id = ? AND session_id IS NOT NULL
      GROUP BY session_id
      ORDER BY first_id DESC
      ''',
      [agentId],
    );
    final sessions = <ChatSessionInfo>[];
    for (final r in rows) {
      final sid = r['session_id'] as String?;
      if (sid == null || sid.isEmpty) continue;
      // First user message of the session, for a human-friendly preview.
      final previewRows = await db.query(
        'messages',
        columns: ['content'],
        where: 'agent_id = ? AND session_id = ? AND role = ?',
        whereArgs: [agentId, sid, 'user'],
        orderBy: 'id ASC',
        limit: 1,
      );
      final preview = previewRows.isEmpty
          ? ''
          : (previewRows.first['content'] as String? ?? '');
      sessions.add(
        ChatSessionInfo(
          sessionId: sid,
          lastTimestamp:
              DateTime.tryParse(r['last_ts'] as String? ?? '') ??
              DateTime.now(),
          messageCount: (r['msg_count'] as int?) ?? 0,
          preview: preview,
        ),
      );
    }
    return sessions;
  }

  /// Load older messages before a given [beforeId] for pagination.
  Future<List<ChatMessage>> loadOlder(
    String agentId, {
    required int beforeId,
    int limit = kMessagePageSize,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'messages',
      where: 'agent_id = ? AND id < ?',
      whereArgs: [agentId, beforeId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.map((r) => ChatMessage.fromRow(r)).toList();
  }

  /// Load all messages (legacy, for small histories).
  Future<List<ChatMessage>> load(String agentId) async {
    final db = await _database;
    final rows = await db.query(
      'messages',
      where: 'agent_id = ?',
      whereArgs: [agentId],
      orderBy: 'id ASC',
    );
    return rows.map((r) => ChatMessage.fromRow(r)).toList();
  }

  /// Get total message count for an agent.
  Future<int> count(String agentId) async {
    final db = await _database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM messages WHERE agent_id = ?',
      [agentId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Append a single message for an agent. Returns the inserted row ID.
  ///
  /// [sessionId] tags the message with the session it belongs to. When null,
  /// the message's own [ChatMessage.sessionId] is used (may also be null for
  /// legacy callers).
  Future<int> addMessage(
    String agentId,
    ChatMessage message, {
    String? sessionId,
  }) async {
    final db = await _database;
    return db.insert('messages', {
      'agent_id': agentId,
      'role': message.role,
      'content': message.content,
      'timestamp': message.timestamp.toIso8601String(),
      'actions': message.actions.isEmpty
          ? null
          : jsonEncode(message.actions.map((a) => a.toJson()).toList()),
      'image_paths': message.imagePaths.isEmpty
          ? null
          : jsonEncode(message.imagePaths),
      'client_id': message.clientId,
      'delivery_status': message.deliveryStatus.label,
      'error_message': message.errorMessage,
      'session_id':
          sessionId ?? message.sessionId ?? _sessionIdResolver?.call(agentId),
      'message_kind': message.kind.label,
      'run_id': message.runId,
      'phase': message.phase,
      'evidence_refs': message.evidenceRefs.isEmpty
          ? null
          : jsonEncode(message.evidenceRefs),
      'context_policy': message.contextPolicy.label,
    });
  }

  Future<void> updateMessage(ChatMessage message) async {
    final id = message.id;
    if (id == null) return;
    final db = await _database;
    await db.update(
      'messages',
      {
        'role': message.role,
        'content': message.content,
        'timestamp': message.timestamp.toIso8601String(),
        'actions': message.actions.isEmpty
            ? null
            : jsonEncode(message.actions.map((a) => a.toJson()).toList()),
        'image_paths': message.imagePaths.isEmpty
            ? null
            : jsonEncode(message.imagePaths),
        'client_id': message.clientId,
        'delivery_status': message.deliveryStatus.label,
        'error_message': message.errorMessage,
        'message_kind': message.kind.label,
        'run_id': message.runId,
        'phase': message.phase,
        'evidence_refs': message.evidenceRefs.isEmpty
            ? null
            : jsonEncode(message.evidenceRefs),
        'context_policy': message.contextPolicy.label,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Append multiple messages at once. All inserted messages are tagged with
  /// [sessionId] when provided (else each message's own sessionId).
  Future<void> addMessages(
    String agentId,
    List<ChatMessage> messages, {
    String? sessionId,
  }) async {
    final db = await _database;
    final batch = db.batch();
    for (final msg in messages) {
      batch.insert('messages', {
        'agent_id': agentId,
        'role': msg.role,
        'content': msg.content,
        'timestamp': msg.timestamp.toIso8601String(),
        'actions': msg.actions.isEmpty
            ? null
            : jsonEncode(msg.actions.map((a) => a.toJson()).toList()),
        'image_paths': msg.imagePaths.isEmpty
            ? null
            : jsonEncode(msg.imagePaths),
        'client_id': msg.clientId,
        'delivery_status': msg.deliveryStatus.label,
        'error_message': msg.errorMessage,
        'session_id':
            sessionId ?? msg.sessionId ?? _sessionIdResolver?.call(agentId),
        'message_kind': msg.kind.label,
        'run_id': msg.runId,
        'phase': msg.phase,
        'evidence_refs': msg.evidenceRefs.isEmpty
            ? null
            : jsonEncode(msg.evidenceRefs),
        'context_policy': msg.contextPolicy.label,
      });
    }
    await batch.commit(noResult: true);
  }

  /// Clear chat history for an agent.
  Future<void> clear(String agentId) async {
    final db = await _database;
    await db.delete('messages', where: 'agent_id = ?', whereArgs: [agentId]);
  }

  /// Clear persisted history for one session while leaving other sessions and
  /// the in-memory UI list alone. Used by `/reset`: same session id, clean
  /// context/history data.
  Future<void> clearSession(String agentId, String sessionId) async {
    final db = await _database;
    await db.delete(
      'messages',
      where: 'agent_id = ? AND session_id = ?',
      whereArgs: [agentId, sessionId],
    );
  }

  /// Delete a single message by row id.
  Future<void> deleteMessage(int id) async {
    final db = await _database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  /// Clear all chat histories.
  Future<void> clearAll() async {
    final db = await _database;
    await db.delete('messages');
  }

  /// Close the database.
  Future<void> close() async {
    final db = await _database;
    await db.close();
    _db = null;
  }
}

enum ChatMessageDeliveryStatus {
  pending,
  sending,
  sent,
  failed;

  String get label => switch (this) {
    ChatMessageDeliveryStatus.pending => 'pending',
    ChatMessageDeliveryStatus.sending => 'sending',
    ChatMessageDeliveryStatus.sent => 'sent',
    ChatMessageDeliveryStatus.failed => 'failed',
  };

  static ChatMessageDeliveryStatus fromLabel(String? raw) {
    return switch (raw) {
      'pending' => ChatMessageDeliveryStatus.pending,
      'sending' => ChatMessageDeliveryStatus.sending,
      'failed' => ChatMessageDeliveryStatus.failed,
      _ => ChatMessageDeliveryStatus.sent,
    };
  }
}

/// Semantic role of a persisted chat bubble.
///
/// Streamed runtime outcomes use a non-conversation kind so the context
/// builder can distinguish an interpretation from snapshot/tool-backed facts.
enum ChatMessageKind {
  conversation,
  analysisSummary,
  planSummary,
  decisionSummary,
  impact,
  nextAction,
  toolInsight,
  toolFailure,
  decisionQuestion;

  String get label => switch (this) {
    ChatMessageKind.conversation => 'conversation',
    ChatMessageKind.analysisSummary => 'analysis_summary',
    ChatMessageKind.planSummary => 'plan_summary',
    ChatMessageKind.decisionSummary => 'decision_summary',
    ChatMessageKind.impact => 'impact',
    ChatMessageKind.nextAction => 'next_action',
    ChatMessageKind.toolInsight => 'tool_insight',
    ChatMessageKind.toolFailure => 'tool_failure',
    ChatMessageKind.decisionQuestion => 'decision_question',
  };

  static ChatMessageKind fromLabel(String? raw) => switch (raw) {
    'analysis_summary' => ChatMessageKind.analysisSummary,
    'plan_summary' => ChatMessageKind.planSummary,
    'decision_summary' => ChatMessageKind.decisionSummary,
    'impact' => ChatMessageKind.impact,
    'next_action' => ChatMessageKind.nextAction,
    'tool_insight' => ChatMessageKind.toolInsight,
    'tool_failure' => ChatMessageKind.toolFailure,
    'decision_question' => ChatMessageKind.decisionQuestion,
    _ => ChatMessageKind.conversation,
  };
}

/// Controls whether a bubble is replayed to the LLM on later turns.
enum ChatContextPolicy {
  include,
  exclude;

  String get label => name;

  static ChatContextPolicy fromLabel(String? raw) =>
      raw == 'exclude' ? ChatContextPolicy.exclude : ChatContextPolicy.include;
}

/// A single chat message.
class ChatMessage {
  ChatMessage({
    this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.actions = const [],
    this.imagePaths = const [],
    this.clientId,
    this.deliveryStatus = ChatMessageDeliveryStatus.sent,
    this.errorMessage,
    this.sessionId,
    this.kind = ChatMessageKind.conversation,
    this.runId,
    this.phase,
    this.evidenceRefs = const [],
    this.contextPolicy = ChatContextPolicy.include,
  }) : timestamp = timestamp ?? DateTime.now();

  factory ChatMessage.outgoing({
    required String content,
    List<String> imagePaths = const [],
  }) {
    return ChatMessage(
      role: 'user',
      content: content,
      imagePaths: imagePaths,
      clientId: const Uuid().v4(),
      deliveryStatus: ChatMessageDeliveryStatus.pending,
    );
  }

  final int? id;
  final String role;
  final String content;
  final DateTime timestamp;

  /// Optional contextual action buttons. Persisted as JSON in the DB.
  final List<ResultAction> actions;

  /// File paths for attached images. Persisted as JSON for thumbnail rendering.
  final List<String> imagePaths;

  /// Stable client-side identity used before SQLite assigns an autoincrement ID.
  final String? clientId;

  /// Local delivery state for optimistic chat UX.
  final ChatMessageDeliveryStatus deliveryStatus;

  /// Optional delivery error detail for failed optimistic messages.
  final String? errorMessage;

  /// Session (context) this message belongs to. Drives LLM context isolation;
  /// null only for legacy rows created before sessions existed.
  final String? sessionId;

  /// Structured metadata for phase-complete streamed runtime bubbles.
  final ChatMessageKind kind;
  final String? runId;
  final String? phase;
  final List<String> evidenceRefs;
  final ChatContextPolicy contextPolicy;

  bool get includeInRuntimeContext =>
      contextPolicy == ChatContextPolicy.include;

  ChatMessage copyWith({
    int? id,
    String? role,
    String? content,
    DateTime? timestamp,
    List<ResultAction>? actions,
    List<String>? imagePaths,
    String? clientId,
    ChatMessageDeliveryStatus? deliveryStatus,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? sessionId,
    ChatMessageKind? kind,
    String? runId,
    String? phase,
    List<String>? evidenceRefs,
    ChatContextPolicy? contextPolicy,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      actions: actions ?? this.actions,
      imagePaths: imagePaths ?? this.imagePaths,
      clientId: clientId ?? this.clientId,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      sessionId: sessionId ?? this.sessionId,
      kind: kind ?? this.kind,
      runId: runId ?? this.runId,
      phase: phase ?? this.phase,
      evidenceRefs: evidenceRefs ?? this.evidenceRefs,
      contextPolicy: contextPolicy ?? this.contextPolicy,
    );
  }

  factory ChatMessage.fromRow(Map<String, dynamic> row) {
    final actionsRaw = row['actions'] as String?;
    final actions = <ResultAction>[];
    if (actionsRaw != null && actionsRaw.isNotEmpty) {
      try {
        final list = jsonDecode(actionsRaw) as List;
        for (final item in list) {
          actions.add(ResultAction.fromJson(item as Map<String, dynamic>));
        }
      } catch (_) {
        // Malformed JSON — ignore.
      }
    }
    final imagePathsRaw = row['image_paths'] as String?;
    final imagePaths = <String>[];
    if (imagePathsRaw != null && imagePathsRaw.isNotEmpty) {
      try {
        final list = jsonDecode(imagePathsRaw) as List;
        for (final item in list) {
          imagePaths.add(item.toString());
        }
      } catch (_) {}
    }
    final evidenceRefs = <String>[];
    final evidenceRefsRaw = row['evidence_refs'] as String?;
    if (evidenceRefsRaw != null && evidenceRefsRaw.isNotEmpty) {
      try {
        evidenceRefs.addAll(
          (jsonDecode(evidenceRefsRaw) as List).map((e) => e.toString()),
        );
      } catch (_) {}
    }
    return ChatMessage(
      id: row['id'] as int?,
      role: row['role'] as String,
      content: row['content'] as String,
      timestamp: DateTime.tryParse(row['timestamp'] as String? ?? ''),
      actions: actions,
      imagePaths: imagePaths,
      clientId: row['client_id'] as String?,
      deliveryStatus: ChatMessageDeliveryStatus.fromLabel(
        row['delivery_status'] as String?,
      ),
      errorMessage: row['error_message'] as String?,
      sessionId: row['session_id'] as String?,
      kind: ChatMessageKind.fromLabel(row['message_kind'] as String?),
      runId: row['run_id'] as String?,
      phase: row['phase'] as String?,
      evidenceRefs: evidenceRefs,
      contextPolicy: ChatContextPolicy.fromLabel(
        row['context_policy'] as String?,
      ),
    );
  }
}

/// Lightweight descriptor of a chat session for `/resume` discovery.
class ChatSessionInfo {
  const ChatSessionInfo({
    required this.sessionId,
    required this.lastTimestamp,
    required this.messageCount,
    required this.preview,
  });

  final String sessionId;
  final DateTime lastTimestamp;
  final int messageCount;
  final String preview;

  /// A short, human-friendly summary derived from the first user message.
  /// Truncated at a word boundary around 50 characters so it fits in a single
  /// line in `/resume` or `/history` output.
  String get title {
    final raw = preview.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (raw.isEmpty) return '(empty session)';
    if (raw.length <= 50) return raw;
    // Cut at the last space before the 50-char mark.
    final cut = raw.lastIndexOf(' ', 50);
    final end = cut > 20 ? cut : 50;
    return '${raw.substring(0, end)}…';
  }
}

final chatHistoryServiceProvider = Provider<ChatHistoryService>(
  (ref) => ChatHistoryService(
    sessionIdResolver: (agentId) =>
        ref.read(chatSessionServiceProvider).currentSessionId(agentId),
  ),
);
