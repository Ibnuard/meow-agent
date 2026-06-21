import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/agent_soul_repository.dart';
import '../../agents/data/agent_model.dart';
import '../../agents/data/agent_repository.dart';
import '../../providers/data/provider_config.dart';
import '../../providers/data/provider_repository.dart';

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

enum ProfileImportMode { merge, replace }

class ProfileImportPreview {
  const ProfileImportPreview({
    required this.agents,
    required this.providers,
    required this.warnings,
    required this.isValid,
  });

  final int agents;
  final int providers;
  final List<String> warnings;
  final bool isValid;
}

class ProfileImportStats {
  const ProfileImportStats({
    required this.agentsAdded,
    required this.agentsSkipped,
    required this.providersAdded,
    required this.providersSkipped,
  });

  final int agentsAdded;
  final int agentsSkipped;
  final int providersAdded;
  final int providersSkipped;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// UI-driven profile backup/restore service. Handles agents (with soul) and
/// providers (without API keys). Parallel to the LLM-driven system.export_all
/// tool but standalone — no runtime context required.
class ProfileBackupService {
  ProfileBackupService({
    required AgentRepository agentRepo,
    required ProviderRepository providerRepo,
    required AgentSoulRepository soulRepo,
  })  : _agentRepo = agentRepo,
        _providerRepo = providerRepo,
        _soulRepo = soulRepo;

  final AgentRepository _agentRepo;
  final ProviderRepository _providerRepo;
  final AgentSoulRepository _soulRepo;

  // ─── Export ───────────────────────────────────────────────────────────────

  /// Build a JSON-serializable snapshot of all agents (with soul) and
  /// providers (without API keys).
  Future<Map<String, dynamic>> buildSnapshot() async {
    final agents = await _agentRepo.loadAll();
    final providers = await _providerRepo.loadAll();

    final agentEntries = <Map<String, dynamic>>[];
    for (final agent in agents) {
      final soul = await _soulRepo.get(agent.id);
      agentEntries.add({
        'agent': agent.toJson(),
        'soul': soul?.toJson(),
      });
    }

    return {
      'version': 2,
      'kind': 'meow.profile',
      'exportedAt': DateTime.now().toIso8601String(),
      'agents': agentEntries,
      'providers': providers.map((p) => p.toPublicJson()).toList(),
    };
  }

  // ─── Validate ─────────────────────────────────────────────────────────────

  /// Validate a snapshot and produce a preview for the user. Checks:
  /// - Shape (version, kind)
  /// - Agent count + provider count
  /// - Orphan references (agent.providerId not in snapshot or DB)
  Future<ProfileImportPreview> validate(Map<String, dynamic> snapshot) async {
    if (snapshot['kind'] != 'meow.profile' ||
        (snapshot['version'] as int? ?? 0) < 2) {
      return const ProfileImportPreview(
        agents: 0,
        providers: 0,
        warnings: [],
        isValid: false,
      );
    }

    final rawAgents = snapshot['agents'] as List? ?? [];
    final rawProviders = snapshot['providers'] as List? ?? [];
    final warnings = <String>[];

    // Collect provider IDs from snapshot.
    final snapshotProviderIds = <String>{};
    for (final raw in rawProviders) {
      if (raw is Map) {
        final id = (raw['id'] ?? '').toString();
        if (id.isNotEmpty) snapshotProviderIds.add(id);
      }
    }

    // Collect provider IDs already in DB.
    final existingProviders = await _providerRepo.loadAll();
    final existingProviderIds = existingProviders.map((p) => p.id).toSet();

    // Check for orphan agent references.
    for (final raw in rawAgents) {
      if (raw is! Map) continue;
      final agentMap = raw['agent'];
      if (agentMap is! Map) continue;
      final name = (agentMap['name'] ?? '').toString();
      final providerId = (agentMap['providerId'] ?? '').toString();
      if (providerId.isNotEmpty &&
          !snapshotProviderIds.contains(providerId) &&
          !existingProviderIds.contains(providerId)) {
        warnings.add(name.isEmpty ? providerId : name);
      }
    }

    return ProfileImportPreview(
      agents: rawAgents.length,
      providers: rawProviders.length,
      warnings: warnings,
      isValid: true,
    );
  }

  // ─── Apply ────────────────────────────────────────────────────────────────

  /// Apply a validated snapshot. Order: providers first (FK constraint),
  /// then agents, then souls.
  Future<ProfileImportStats> apply(
    Map<String, dynamic> snapshot, {
    required ProfileImportMode mode,
  }) async {
    final rawAgents = snapshot['agents'] as List? ?? [];
    final rawProviders = snapshot['providers'] as List? ?? [];

    int providersAdded = 0;
    int providersSkipped = 0;
    int agentsAdded = 0;
    int agentsSkipped = 0;

    if (mode == ProfileImportMode.replace) {
      // Delete agents first (cascades soul/memory/events), then providers.
      final existingAgents = await _agentRepo.loadAll();
      for (final a in existingAgents) {
        await _agentRepo.delete(a.id);
      }
      final existingProviders = await _providerRepo.loadAll();
      for (final p in existingProviders) {
        await _providerRepo.delete(p.id);
      }
    }

    // 1. Insert providers.
    final existingProviderIds =
        (await _providerRepo.loadAll()).map((p) => p.id).toSet();
    for (final raw in rawProviders) {
      if (raw is! Map) continue;
      final json = Map<String, dynamic>.from(raw);
      final config = ProviderConfig.fromPublicJson(json, apiKey: '');
      if (mode == ProfileImportMode.merge &&
          existingProviderIds.contains(config.id)) {
        providersSkipped++;
        continue;
      }
      await _providerRepo.save(config);
      providersAdded++;
    }

    // 2. Insert agents + souls.
    final existingAgentNames =
        (await _agentRepo.loadAll()).map((a) => a.name.toLowerCase()).toSet();
    // Refresh provider IDs after inserts.
    final currentProviderIds =
        (await _providerRepo.loadAll()).map((p) => p.id).toSet();

    for (final raw in rawAgents) {
      if (raw is! Map) continue;
      final agentJson = raw['agent'];
      if (agentJson is! Map) continue;
      final agentMap = Map<String, dynamic>.from(agentJson);
      final agent = AgentModel.fromJson(agentMap);

      // Skip if provider doesn't exist (orphan).
      if (agent.providerId.isNotEmpty &&
          !currentProviderIds.contains(agent.providerId)) {
        agentsSkipped++;
        continue;
      }

      // Skip duplicates in merge mode.
      if (mode == ProfileImportMode.merge &&
          existingAgentNames.contains(agent.name.toLowerCase())) {
        agentsSkipped++;
        continue;
      }

      await _agentRepo.save(agent);
      agentsAdded++;

      // Populate soul data if present.
      final soulJson = raw['soul'];
      if (soulJson is Map && soulJson.isNotEmpty) {
        final soul = AgentSoul.fromJson(Map<String, dynamic>.from(soulJson));
        // Override agentId to match the agent we just saved.
        final corrected = AgentSoul(
          agentId: agent.id,
          userName: soul.userName,
          userNickname: soul.userNickname,
          preferredLanguage: soul.preferredLanguage,
          timezone: soul.timezone,
          workRole: soul.workRole,
          mainProject: soul.mainProject,
          communicationStyle: soul.communicationStyle,
          designPreference: soul.designPreference,
          persona: soul.persona,
          personaMeta: soul.personaMeta,
          updatedAt: soul.updatedAt,
        );
        await _soulRepo.updateAll(corrected);
      }
    }

    return ProfileImportStats(
      agentsAdded: agentsAdded,
      agentsSkipped: agentsSkipped,
      providersAdded: providersAdded,
      providersSkipped: providersSkipped,
    );
  }

  /// Encode a snapshot to a pretty-printed JSON string.
  static String encodeSnapshot(Map<String, dynamic> snapshot) {
    return const JsonEncoder.withIndent('  ').convert(snapshot);
  }

  /// Decode a JSON string into a snapshot map. Returns null on parse error.
  static Map<String, dynamic>? decodeSnapshot(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Riverpod Provider
// ---------------------------------------------------------------------------

final profileBackupServiceProvider = Provider<ProfileBackupService>((ref) {
  return ProfileBackupService(
    agentRepo: ref.read(agentRepositoryProvider),
    providerRepo: ref.read(providerRepositoryProvider),
    soulRepo: ref.read(agentSoulRepositoryProvider),
  );
});
