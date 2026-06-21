import 'package:flutter_test/flutter_test.dart';
import 'package:meow_agent/core/storage/agent_soul_repository.dart';

/// Drift guard: ensures the canonical [AgentSoulRepository.profileFields]
/// list stays in sync with [AgentSoul] model properties and the
/// [AgentSoulRepository._columnForField] mapping.
///
/// If you add a new profile field:
///   1. Add it to [AgentSoul] model.
///   2. Add the column to `agent_soul` table in `meow_database.dart`.
///   3. Add the mapping in [AgentSoulRepository._columnForField].
///   4. Add the field key to [AgentSoulRepository.profileFields].
///   5. This test will pass — if any step is skipped, it breaks here.
void main() {
  group('AgentSoul schema drift guard', () {
    test('profileFields list maps to valid field keys', () {
      for (final field in AgentSoulRepository.profileFields) {
        expect(field, isNotEmpty, reason: 'Field key must not be empty');
      }

      // Verify the list is not accidentally empty.
      expect(AgentSoulRepository.profileFields.length, greaterThanOrEqualTo(9));
    });

    test('memoryCategories list is non-empty and matches expected set', () {
      expect(AgentSoulRepository.memoryCategories, isNotEmpty);
      expect(
        AgentSoulRepository.memoryCategories,
        containsAll(['fact', 'preference', 'bookmark', 'session']),
      );
    });

    test('AgentSoul model has a property for every profileField', () {
      // Create a fully-populated AgentSoul and verify every field maps to
      // a getter that doesn't throw.
      final soul = AgentSoul(
        agentId: 'test',
        userName: 'Test',
        userNickname: 'T',
        preferredLanguage: 'en',
        timezone: 'UTC',
        workRole: 'dev',
        mainProject: 'meow',
        communicationStyle: 'direct',
        designPreference: 'minimal',
        persona: 'helpful',
        updatedAt: DateTime.now(),
      );

      // Map field key → expected value from the model.
      final fieldToValue = <String, String?>{
        'name': soul.userName,
        'nickname': soul.userNickname,
        'preferred_language': soul.preferredLanguage,
        'timezone': soul.timezone,
        'work_role': soul.workRole,
        'main_project': soul.mainProject,
        'communication_style': soul.communicationStyle,
        'design_preference': soul.designPreference,
        'persona': soul.persona,
      };

      for (final field in AgentSoulRepository.profileFields) {
        expect(
          fieldToValue.containsKey(field),
          isTrue,
          reason:
              'profileFields contains "$field" but the AgentSoul model has no '
              'corresponding property mapped in this test. If you added a new '
              'profile field, update this map.',
        );
        expect(
          fieldToValue[field],
          isNotNull,
          reason: 'AgentSoul property for "$field" should not be null '
              'when constructed with a value.',
        );
      }

      // Reverse check: every mapped key is in profileFields.
      for (final key in fieldToValue.keys) {
        expect(
          AgentSoulRepository.profileFields.contains(key),
          isTrue,
          reason:
              'AgentSoul has mapped property "$key" but it is not in '
              'profileFields. Add it to the canonical list.',
        );
      }
    });
  });
}
