# Meow Agent — Speed Optimization Analysis

> Comparison: **Meow Agent (runtime-v5)** vs **OpenClaw Gateway**  
> Goal: Make Meow Agent as fast as OpenClaw on mobile

---

## 🔍 Current Architecture (Meow Agent)

### Prompt Build Flow
```
SQLite (soul + memory + skills) → WorkspaceContextBuilder → PromptTemplates
       ↓
   Tiap LLM call rebuild ulang dari awal
```

### Turn Flow (Agentic)
```
User Message
  → ANALYZE  (LLM call #1: 12K tokens)
  → REFLECT  (LLM call #2: 12K tokens, skippable)
  → PLAN     (LLM call #3: 12K tokens, skippable)
  → EXECUTE LOOP (LLM call #4+: selectTool, review per step)
  → VERBALIZE (LLM call final)

Total: 2-6 LLM calls per turn
Prefix dibayar ulang setiap call — 0% reuse
```

### Key Stats
| Metric | Value |
|--------|-------|
| LLM calls per turn | 2-6 |
| Token estimation | ~3.2 chars/token |
| Compaction threshold | 80% of max context |
| Timeout | connect 60s, receive 300s |
| Provider cache | ❌ None |
| Prompt prefix stability | ❌ Variabel per phase |

---

## 🏗️ OpenClaw Architecture (Reference)

### Prompt Build Flow
```
Session start: Build full prompt ONCE
     ↓
Cache boundary: stable tools/rules/soul above, dynamic history below
     ↓
Provider caches prefix → subsequent turns reuse via cacheRead
```

### Turn Flow
```
User Message
  → Single LLM call with tools[] + structured output
  → If tool_calls → execute → inject result → continue
  → If done → respond

Total: 1+ LLM calls (only extra if tools needed)
Prefix: paid ONCE, reused via cacheRead = free
```

---

## 🎯 Root Causes of Slowness

### 1. Multi-phase LLM calls × Zero caching
- Every turn: 4-6 separate LLM calls
- Prefix (soul + memory + tools + rules) sent fresh each time
- 12K token prefix × 5 calls = **60K tokens wasted** per turn on identical content

### 2. Unstable prompt prefix
- `prompt_templates.dart`: section order changes per phase
- `vmBlock`, `sourceModeBlock`, `predefinedSkillsBlock` — conditional inserts shift prefix position
- Even 1 char difference = cache break → full re-process

### 3. ✅ Chat bypass sudah implemented
- `_tryChatRoute()` → `planner.chatRoute()` — lightweight LLM classify
- Chat langsung return `direct_response`, skip analyze/reflect/plan/execute
- Agentic route tetap lanjut full pipeline
- **Bukan bottleneck lagi**

### 4. Token estimation only — no actual provider caching
- `ContextCompactor` estimates with `text.length / 3.2`
- No `prompt_cache_key`, no `cache_control` markers, no provider-side reuse

---

## 💡 Recommendations (Ordered by Impact)

### Level 1: Provider Prompt Caching ⚡⚡⚡
*High impact · Medium effort · Backward compatible*

```dart
// openai_compatible_client.dart
class OpenAiCompatibleClient {
  static String _sessionCacheKey = '';

  static void initSession(String sessionId) {
    _sessionCacheKey = sessionId;
  }

  Future<Map<String, dynamic>> _postWithCache({
    required Uri uri,
    required Map<String, dynamic> body,
    required LlmProviderConfig config,
    CancelToken? cancelToken,
  }) async {
    final headers = <String, dynamic>{};
    if (_sessionCacheKey.isNotEmpty && config.supportsCache) {
      headers['prompt_cache_key'] = _sessionCacheKey;
      headers['prompt_cache_retention'] = '24h';
    }
    // ... existing headers ...
    return _dio.postUri(uri,
      data: body,
      options: Options(headers: headers),
      cancelToken: cancelToken,
    );
  }
}
```

**Requirements:**
- Provider must support `prompt_cache_key` (DeepSeek, OpenAI compatible)
- System prompt prefix must be byte-identical across turns

### Level 2: Stable Prompt Prefix ⚡⚡⚡
*Foundation for Level 1 · Medium effort*

Restructure `PromptTemplates` to split stable vs dynamic:

```dart
class PromptTemplates {
  /// NEVER changes during a session — cached by provider
  static String stablePrefix({
    required String language,
    required String soul,
    required String skills,
    required List<String> toolDefinitions, // SORTED alphabetically
    String phaseSpecific = '',             // ONLY analyze/select/review rules
  }) {
    final sortedTools = List<String>.from(toolDefinitions)..sort();
    return '''
SYSTEM RULES (language: $language)
$soul

SKILLS:
$skills

TOOLS:
${sortedTools.join('\n')}

$phaseSpecific
''';
  }

  /// Changes every turn — NOT cached
  static String dynamicSuffix({
    required String userMessage,
    required String recentHistory,
    required String memory,
    String pendingAction = '',
  }) {
    return '''
RECENT CONVERSATION:
$recentHistory

MEMORY:
$memory

$pendingAction

USER MESSAGE: "$userMessage"
''';
  }
}
```

**Key rules:**
- Tool list: always sorted, same order every call
- No conditional blocks above the boundary
- Phase-specific rules go at the top (same position every call for that phase)

### Level 3: Reduce Phase LLM Calls ⚡⚡
*High impact · Structural change · Breaks golden tests*

Merge analyze + reflect + plan into **one** LLM call:

```dart
Future<AnalysisResult> analyzeAndPlan({
  required String userMessage,
  required AgentWorkspace workspace,
  required List<ToolDefinition> tools,
}) async {
  final response = await client.chat(
    systemPrompt: stablePrefix + dynamicSuffix,
    responseFormat: {'type': 'json_object'},
    cancelToken: cancelToken,
  );
  // Returns: route, intent, selected_skill_ids, goal_tree, missing_info
  // ALL in one response
}
```

**Before:** analyze(1) + reflect(1) + plan(1) = 3 LLM calls, 36K+ tokens  
**After:** 1 LLM call, 12K tokens → **66% reduction**

### Level 4: ✅ Chat Bypass — DONE
*Already implemented in runtime-v5*

Flow: `run()` → `_tryChatRoute()` → `planner.chatRoute()` → jika route=chat & direct_response ada → return langsung

**Possible improvement:** Chat route masih LLM call juga (ringan). Bisa diganti murni deterministic classifier (keyword/heuristic) di masa depan buat hemat 1 LLM call lagi.

### Level 5: Session-Level Context Reuse ⚡
*Medium effort · Infrastructure*

```dart
class AgentSession {
  final String id;
  String _cachedSystemPrefix;       // Built once
  List<ToolDefinition> _cachedTools; // Sorted, frozen
  DateTime _prefixBuiltAt;

  String get systemPrefix {
    if (_isStale) rebuild();
    return _cachedSystemPrefix;
  }
}
```

Don't rebuild soul/memory/tools from SQLite every turn. Rebuild only when user edits them.

### Level 6: Prewarm Cache on Session Start
*Low effort · Smoother UX*

```dart
// On chat screen open / agent switch
void prewarmCache() {
  final prefix = PromptTemplates.stablePrefix(...);
  client.chat(
    messages: [{'role': 'system', 'content': prefix}],
    phase: '_cache_warm',
    max_tokens: 1, // Don't waste output tokens
  );
  // Ignore result — just warming the cache
}
```

---

## 📊 Expected Impact

| Improvement | Token Saved | Latency Gain | Effort |
|---|---|---|---|
| Level 1: Provider caching | 60-80% reuse | 30-50% per call | Medium |
| Level 2: Stable prefix | Foundation | Enables Level 1 | Medium |
| Level 3: Merge phases | 66% fewer calls | 60-70% turn time | Large |
| Level 4: Chat bypass | ✅ DONE | ✅ DONE | — |
| Level 5: Session reuse | Eliminates DB reads | -200ms cold | Medium |
| Level 6: Prewarm | Smooth UX | -2s first turn | Small |

**Best path (updated):** Level 2 → Level 1 → Level 3  
Level 4 ✅ sudah done.

---

## ⚠️ Important Caveats

1. **Provider support:** `prompt_cache_key` works on DeepSeek, OpenAI. Test `prompt_tokens_details.cached_tokens` field in response to confirm.
2. **Cache break detection:** Monitor for unexplained `cacheWrite` spikes — means prefix changed.
3. **Tool sort MUST be deterministic.** Alphabetical. Always. One deviation = cache break.
4. **Phase merging complicates debugging.** Keep verbose logging of the merged response.
5. **Vision turns (images) may not cache.** Image content changes every time — plan for that.

---

## 🔗 Next Steps

1. **[Quick Win]** Implement Level 4 (chat bypass) — already planned, just needs code
2. **[Foundation]** Refactor prompt templates per Level 2 — stable prefix architecture
3. **[Enable]** Add `prompt_cache_key` header per Level 1
4. **[Validate]** Measure `cached_tokens` in LLM responses to confirm caching works
5. **[Optimize]** Phase merge per Level 3 after stable foundation is verified

---

*Generated: 2026-06-26 · Source: Meow Agent runtime-v5 @ Ibnuard/meow-agent*
