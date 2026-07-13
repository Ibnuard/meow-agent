# Meow Agent Runtime v5 — Critical Analysis

> **Repo:** `github.com/Ibnuard/meow-agent` (branch `runtime-v5`)  
> **Analyst:** zen_sun (Surya)  
> **Date:** 2026-07-02

---

## 🔴 Root Cause: OVER-PROMPTING + OVER-LLM-CALLING

Runtime memaksa LLM mikir ulang dari nol di setiap langkah, padahal semua data ada di SQLite — deterministik & bisa di-resolve tanpa LLM.

---

## Critical Issue #1: Prompt BLOAT — Prefix 12K+ token tiap LLM call

Setiap LLM call (classify, selectTool, review), kirim:

| Block                                                                 | Perkiraan token       |
| --------------------------------------------------------------------- | --------------------- |
| World Model (who you are + how you work + full DB schema + ecosystem) | ~1100                 |
| Soul Character                                                        | ~150                  |
| Self Identity                                                         | ~50                   |
| Workspace (soul + memory + skills dari SQLite)                        | ~500-2000             |
| System Rules                                                          | ~300                  |
| Phase-specific rules & JSON schema                                    | ~1500-3000            |
| Available tools (40+ tools full definition)                           | ~2000-4000            |
| History + previous results                                            | ~500-2000             |
| **Total per LLM call**                                                | **~8000-14000 token** |

**Contoh task simpel 3 subgoal = 7 LLM call:**

```
classify     → 12K token
selectTool#1 → 12K token (lagi)
review#1     → 12K token (lagi)
selectTool#2 → 12K token (lagi)
review#2     → 12K token (lagi)
selectTool#3 → 12K token (lagi)
review#3     → 12K token (lagi)
─────────────────────────
TOTAL         = 84K token
```

**84K token cuma buat prefix yang SAMA diulang 7 kali.**

---

## Critical Issue #2: No Deterministic Route for Simple Operations

Task simpel kayak `"insert data ke table expenses"`:

**Flow yang terjadi sekarang:**

```
classify (1 LLM call, 12K token)
  → extract intent → "db.insert"
  → emit subgoals
selectTool (1 LLM call, 12K token)
  → pilih db.insert dari 40+ tools
review (1 LLM call, 12K token)
  → cek result → "done"
─────────────────
3 LLM calls untuk 1 SQLite INSERT
```

**Flow yang seharusnya:**

```
Parse intent → "db.insert ke expenses"
Validasi table exists via SQLite (deterministic)
Eksekusi db.insert (SQLite, instant)
Return result
─────────────────
0-1 LLM call
```

Itu sebabnya task simple lama banget — LLM dipanggil buat hal yang 100% deterministik.

---

## Critical Issue #3: Tool Catalog Narrowing GAGAL

Di `tool_catalog.dart`:

- **Pre-analyze:** `confidence=0` → SEMUA tools dikirim (40+ tools full definition)
- **Post-analyze:** narrowing cuma jalan kalau analyzer ngasih `tool_groups` yang valid
- Kalau model kecil/lemah → narrowing ga jalan → **selectTool harus milih dari ALL tools**

Padahal user cuma minta `db.query`. Tapi LLM disodorin 40 tools termasuk `app.open`, `miniapp.create`, `workflow.schedule`, `communication.send`, dll.

---

## Critical Issue #4: Execution Loop Budget TERLALU BESAR

```dart
final adaptiveLimit = fastPath
    ? 2
    : goalTree.isEmpty
        ? maxSteps           // 5
        : (maxSteps + goalTree.subgoals.length * 2)
              .clamp(maxSteps, maxSteps * 3);  // 5-15 iterasi
```

- Task 3 subgoal = **11 iterasi loop LLM**
- Plus classify = **12 LLM call minimum**
- Stuck detector + recovery = **RETHINK via LLM call tambahan**

---

## Critical Issue #5: stableContext ADA tapi Tidak Menyelesaikan Masalah

`prompt_templates.dart` ada `buildStableContext()` buat prompt caching, tapi:

1. **Cuma prefix** — selectTool & review masih kirim 3000+ token context spesifik
2. **Caching provider-dependent** — banyak model kecil ga support / unreliable
3. **Conditional blocks** — `vmBlock`, `miniAppBlock`, `isWorkflowAutoExecute` bikin prefix berubah antar call → cache break

---

## Critical Issue #6: Review "done" Gate Belum Deterministic

**Dari LOW_MODEL.md (dokumentasi sendiri):**

> "review returns status=done → ExecuteLoopRunner checks: goalTree.isComplete? → If yes: accept done"
> "But goalTree.isComplete only checks subgoal status labels. It does NOT check whether the subgoal's actual semantic outcome was achieved"

Kalau reviewer hallucinate `done`, engine langsung exit. Hasil: **task incomplete diklaim success.**

`requiredCapabilities` baru dicek buat `codeInspection` miniapp — **buat operasi DB simpel, ga ada verification probe sama sekali.**

---

## Critical Issue #7: Tidak Ada Composite/Chained Tool

Pattern `"create table → insert data → tampilkan"` butuh 3 LLM call buat milih tool satu-satu. **Ga ada composite tool** yang bisa chain operasi SQLite secara deterministik dalam 1 eksekusi.

---

## 📊 Rekomendasi (Prioritas)

### 🔴 P0 — Deterministic Route untuk Simple Tasks

Bikin **rule-based engine** yang intercept SEBELUM LLM:

```
if intent matches:
  db.insert, db.query, db.update, db.delete,
  notes.create, notes.search,
  clipboard.read, clipboard.write,
  ...dan pattern simple lainnya

→ langsung execute via SQLite (deterministik)
→ 0-1 LLM call untuk verbalize/format result
```

**Impact:** Dari 3-7 LLM call ke 0-1 per turn.

### 🔴 P0 — Semantic Verification Gate

Sebelum accept review `done`, verify secara deterministik:

- `codeInspection.*` flags vs `requiredCapabilities`
- Data presence (query result not empty, insert confirmed)
- Subgoal completion criteria terpenuhi

### 🟡 P1 — Aggressive Tool Surface Narrowing

Tambahin **keyword-based narrowing** di engine level:

- `"database"/"table"/"db"/"sql"` → cuma kirim db + sqlite tools
- `"note"/"catat"/"tulis"` → cuma kirim notes tools
- `"file"/"baca"/"buka"` → cuma kirim files tools

Jangan cuma andelin analyzer LLM — narrowing harus jalan secara deterministik.

### 🟡 P1 — Eliminasi DB Schema dari Prompt

Schema `meow_core.db` (agents, agent_soul, providers, modules, dll) ada di SQLite. LLM bisa query `sqlite.query` untuk schema secara real-time. Ga perlu dikirim statis tiap prompt → hemat ~500 token/call.

### 🟢 P2 — Composite/Chained Tools

Shortcut untuk pattern umum:

- `db.ensure_table_and_insert` → 1 tool ganti create_table + insert
- `db.query_and_format` → 1 tool ganti query + verbalize
- `notes.create_from_clipboard` → 1 tool ganti clipboard.read + notes.create

---

## 📈 TL;DR

| Masalah                | Token Waste     | LLM Calls         | Fix Priority |
| ---------------------- | --------------- | ----------------- | ------------ |
| Prefix bloating        | ~84K/task       | 7x redundant      | P0           |
| No deterministic route | ~36K            | 3x per simple op  | P0           |
| Review gate lemah      | task incomplete | hallucinated done | P0           |
| Tool catalog too wide  | ~4K/call        | salah milih tool  | P1           |
| DB schema in prompt    | ~500/call       | unnecessary       | P1           |
| No composite tools     | ~36K/task       | chain overhead    | P2           |

**Target:** Simple DB task dari 36K token + 3 LLM call → **~5K token + 0-1 LLM call** (7x lebih cepat).
