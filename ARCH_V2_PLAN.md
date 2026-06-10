# ARCH V2 Plan

## Goal

System config state → **single source of truth: `meow.json`**.  
Module/action tools tetap existing. Yang diubah: **system-based config tools**.

---

## Target boundary

Tetap:

```text
module tools:
- notes.create
- app.open
- device.battery
- workflow.run
- chat/runtime actions
```

Ubah:

```text
system.agents.create/update/delete
system.providers.*
system.modules.toggle
user prefs/state
active agent/provider/module config
```

Menjadi:

```text
system.config.read
system.config.patch
```

Opsional:

```text
system.config.validate
system.config.backup
```

Tapi idealnya backup/validate internal di `patch`.

---

## Proposed architecture

```text
meow.json
  ↓
MeowConfigRepository
  ↓
App repositories/providers
  ↓
Runtime snapshot + UI state
```

`meow.json` = authoritative config state.

Repos existing jangan langsung hilang dulu. Jadikan adapter:

```text
AgentRepository      → backed by MeowConfigRepository
ProviderRepository   → backed by MeowConfigRepository
ModuleRepository     → backed by MeowConfigRepository
Prefs provider       → backed by MeowConfigRepository
```

Jadi UI existing minim break.

---

## File model

Lokasi ideal:

```text
app data dir/meow.json
app data dir/meow.backups/meow-<timestamp>.json
```

Bukan workspace agent. Ini app-level config, bukan user document.

Shape:

```json
{
  "schemaVersion": 1,
  "activeAgentId": "default",
  "activeProviderId": "main",
  "prefs": {
    "language": "system",
    "theme": "dark"
  },
  "providers": [],
  "agents": [],
  "modules": {}
}
```

API key:

```json
{
  "apiKeyRef": "secure://provider-id"
}
```

Jangan plaintext di `meow.json`.

---

## Write safety

Every write:

```text
read current
→ validate current
→ backup current
→ apply patch
→ validate next
→ atomic write temp
→ reload
→ verify state
```

Boot:

```text
load meow.json
→ if missing: create default
→ if invalid: restore latest valid backup
→ if no backup: create default + report recovery
```

Atomic write:

```text
meow.json.tmp → fsync/flush → rename meow.json
```

---

## Runtime knowledge change

Add to system knowledge/prompt:

```text
System configuration lives in meow.json.
For config changes, read config, patch JSON, validate.
Never invent config state.
Before mutating meow.json, runtime creates backup.
If meow.json is invalid, runtime restores latest valid backup.
```

Prompt examples English-only.

---

## Tool surface

Replace many config tools with:

### `system.config.read`

Input:

```json
{
  "path": "$",
  "includeSecrets": false
}
```

Output:

```json
{
  "config": {},
  "schemaVersion": 1,
  "valid": true
}
```

### `system.config.patch`

Input:

```json
{
  "operations": [
    {
      "op": "add",
      "path": "/agents/-",
      "value": {}
    }
  ],
  "reason": "Create a new agent named X"
}
```

Use RFC6902-ish JSON Patch.

Output:

```json
{
  "success": true,
  "backupId": "...",
  "changedPaths": ["/agents"],
  "configHash": "..."
}
```

`verificationProbe`: re-read `meow.json` + assert changed path.

---

## Tool naming migration

Phase 1 keep aliases:

```text
system.agents.create → wrapper around system.config.patch
system.agents.update → wrapper around system.config.patch
system.agents.delete → wrapper around system.config.patch
system.modules.toggle → wrapper around system.config.patch
```

Phase 2 hide aliases from catalog, keep dispatch compat for old tests/pending actions.

Phase 3 remove or internal-only.

---

## Snapshot impact

Update `EcosystemSnapshotBuilder`:

```text
before: AgentRepository + ProviderRepository + ModuleRepository
after: MeowConfigRepository snapshot
```

But expose same `EcosystemAgent/EcosystemProvider` models to avoid breaking resolver.

---

## Completion verification

Update verifier from tool-name-specific checks:

Current smells:

```text
completion_verifier.dart checks system.agents.create/delete
```

New:

```text
verify changed config path/state:
- agent exists/absent
- provider exists/active
- module enabled/disabled
```

No “success” from LLM. Re-read config.

---

## Tests

Add:

```text
test/meow_config_repository_test.dart
```

Covers:

1. missing file → default generated
2. valid file loads
3. invalid JSON → restore backup
4. invalid schema → restore backup
5. patch creates backup first
6. patch failure → no corrupt write
7. agent add/edit/delete via patch
8. module toggle via patch
9. provider secret excluded / `apiKeyRef` only
10. migration schema v1→v2 later

Update:

```text
test/runtime_golden_test.dart
test/module_plugin_test.dart
```

Golden expected tool flow becomes:

```text
system.config.read
system.config.patch
```

Not:

```text
system.agents.create
```

---

## Migration sequence

1. Add `MeowConfig` models + schema validator.
2. Add `MeowConfigRepository` with ensure/load/backup/patch/restore.
3. Generate `meow.json` on app startup.
4. Back existing repos by `MeowConfigRepository`.
5. Add `system.config.read/patch`.
6. Convert existing system CRUD tools to wrappers.
7. Update prompts: config architecture knowledge.
8. Update snapshot/verifier to config-backed state.
9. Hide old system config tools from catalog.
10. Run golden + drift guard.
11. Remove deprecated wrappers later.

---

## Biggest risk

LLM patching raw JSON bisa salah path/value.

Mitigation:

```text
patch tool validates semantic invariants:
- activeAgentId must exist
- agent.providerId must exist
- activeProviderId must exist
- module settings known
- duplicate agent/provider names rejected
- no secret plaintext fields
```

So generic tool, but not dumb file write.  
It is **config-aware generic patch**, not unrestricted JSON overwrite.

---

## Verdict

Plan ini paling clean:

```text
meow.json = source of truth
system config tools = read/patch only
module action tools = unchanged
repos/UI = adapter layer
backup/validate/restore = repository responsibility
LLM = understands architecture, not per-action tools
```

Ini sesuai AGENTS.md: generic, language-agnostic, validation-before-declaration, no per-case tool explosion.
