# Foundation Modular Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make the exported foundation safer to extend with domain modules, while fixing confirmed conversation, audio, and memory consistency races.

**Architecture:** Preserve the existing Flutter/Riverpod service wiring and single LLM tool loop. Add pure Dart application and domain-context contracts, retain legacy AssistantModule entry points, and guard every asynchronous UI update with request ownership. Keep canonical SQLite facts authoritative over vector projections.

**Tech Stack:** Flutter, Dart ^3.12.0, Riverpod 3, sqflite, existing ASR/TTS/DUIX adapters.

**Spec:** docs/design/2026-10-05-foundation-optimization.md carries the text of the user-approved 通用数字人底座优化与迁移方案_v1.0.docx, together with docs/FOUNDATION_INTERFACES.zh-CN.md and docs/FOUNDATION_OVERVIEW.zh-CN.md. This repository is the foundation-only public export at ed823832aa92ac45729bbf6ba99bee48e45c010c; the private health application is not present.

## Global Constraints

- Preserve foundation package ID, native channel names, database path ai_secretary.db, schema version 6, and all existing tables and migration gates.
- Keep the existing AssistantModule implementations source-compatible; health proposal confirmation semantics remain unchanged.
- SOE is optional and disabled by default. No cloud account, SOE SDK, raw-audio queue, or vendor/model assets are prerequisites for this change.
- Do not add a second tool loop or claim full response APIs are true streaming.
- Preserve already committed business records when a response is interrupted.
- No private credentials, signing files, proprietary DUIX assets, or ASR model weights enter commits.
- Implement useful regression tests against real application behavior; do not test source-text patterns or private structure.

## Scope and migration decisions

This change implements the independently verifiable first integration stage: application/context contracts, request ownership, source-aware memory consistency, and audio-view cleanup. It does not invent study business repositories, a universal transaction ledger, cloud synchronization, physical database moves, or a full namespace migration. Those need the consuming domain and a separately tested schema migration. The documentation must retain these distinctions rather than claim all O0–O6 targets are implemented.

## Review Focus

- A late callback after clear, switch, cancellation, or provider disposal must not overwrite a newer turn.
- An input must keep the ASR engine and domain focus captured when it started, even if settings or UI focus change while awaiting recognition.
- Adding or mutating modules after registration must not bypass duplicate-name checks or change an already captured tool selection.
- A deleted, expired, or changed canonical fact must not reappear through a late embedding or stale vector result.
- Failure from an old avatar view must not stop audio owned by a newer view; unavailable optional analysis must not delay ordinary conversation.

---

### Task 1: Application and context contracts

**Files:**
- Create: lib/core/app_profile.dart
- Create: lib/core/assistant/assistant_context.dart
- Modify: lib/core/assistant/assistant_module.dart
- Modify: lib/providers/assistant_modules_provider.dart
- Modify: lib/foundation_app.dart
- Modify after Task 2: lib/providers/chat_provider.dart, lib/providers/digital_human_provider.dart
- Test: test/assistant_context_test.dart, test/assistant_module_registry_test.dart, test/foundation_edition_test.dart

**Interfaces:**
- Produces AppProfile(id, dataNamespace, allowedModuleIds) with an immutable optional module allowlist.
- Produces AssistantContextSnapshot(namespace, moduleIds, focus, taskId, expiresAt) and AssistantEntityRef(namespace, type, id, revision).
- Adds optional context-aware selection/invocation while retaining matches(text), invoke(name, args, sessionId, turnId), and proposal hooks.
- Produces assistantAppProfileProvider and assistantContextProvider; consumers capture a snapshot before awaiting input processing.

- [x] Write regression tests for mutable registry input, duplicate tool names, expired/cross-namespace focus, allowlist exclusion, context-only selection, and old module invocation.
- [x] Run the focused tests and record the expected failing behavior.
- [x] Implement immutable registration/context snapshots and context-aware module defaults; make the application assembly validate registered module IDs.
- [x] Capture context in text and microphone entry paths and use the same snapshot for prompt guidance and tool invocation.
- [x] Run focused tests plus existing web-search and foundation routing tests.

### Task 2: Conversation ownership and cancellation

**Files:**
- Modify: lib/providers/chat_provider.dart
- Modify: lib/providers/digital_human_provider.dart
- Modify if needed: lib/services/call_foreground_service.dart
- Test: test/chat_request_lifecycle_test.dart
- Test: test/digital_human_lifecycle_test.dart
- Test if needed: test/call_foreground_service_test.dart

**Interfaces:**
- Preserves existing public notifier methods and service providers.
- Request validity includes provider lifetime and the captured request generation.
- Voice input owns its starting AsrEngine until finish/cancel; a settings change cannot retarget the active capture.
- Native callback registration may return an ownership-aware unsubscriber; callers that ignore the return value remain compatible.

- [x] Write delayed-service tests that reproduce late context, history, or assistant indexing responses after switching/clearing a session.
- [x] Write delayed-setting/TTS and ASR latency tests that reproduce late speech after interruption and engine changes during recording.
- [x] Run and observe the failures before modifying production behavior.
- [x] Add ownership checks at asynchronous boundaries, capture request messages, prevent stale callbacks from replacing the newest subscription/state, and preserve committed rows.
- [x] Include speed commands in the normal cancellation generation, clear capture state consistently, and unregister obsolete native callbacks on disposal.
- [x] Run all lifecycle tests and the existing suite; report any hardware-only gap separately.

### Task 3: Canonical memory and index consistency

**Files:**
- Modify: lib/core/database/database_helper.dart
- Modify: lib/services/memory_service.dart
- Modify: lib/services/rag_service.dart
- Modify if required: lib/services/memory_policy.dart
- Test: test/memory_service_test.dart, test/rag_service_test.dart

**Interfaces:**
- Preserves DatabaseHelper.insertMemory(MemoryEntry) -> Future<int> and schema version 6.
- Serializes same-key merge in a transaction and projects the actual saved record, not a rejected incoming value.
- Explicit manual/user_input facts cannot be silently overwritten by conflicting ai_extract guesses; later explicit user corrections remain possible.
- RagService search validates managed source records before final result selection; repair reports actual failure without blocking ordinary chat on embedding availability.

- [x] Add tests for conflicting AI updates, later user corrections, concurrent same-key writes, and one profile embedding per extracted fact.
- [x] Add tests for expired/deleted/changed sources, embedding completion after source deletion/change, valid candidates behind stale results, and failed index repair.
- [x] Run the failing regressions.
- [x] Implement transaction-safe merges, stored-record projection, managed-source validation before retrieval/upsert, and truthful repair results.
- [x] Remove the duplicated profile update/embedding after _saveMemory already projected the fact.
- [x] Run the memory/RAG suite and verify no table, file, or migration version changes.

### Task 4: Audio ownership compatibility

**Files:**
- Modify: lib/services/avatar_audio_bridge.dart
- Test: test/tts_avatar_bridge_test.dart

**Interfaces:**
- Preserves AvatarAudioBridge.play/stop and current false-versus-error fallback semantics.
- A play request's failure cleanup targets the channel captured by that request.

- [x] Add a two-channel delayed-failure regression proving that channel A cannot stop channel B.
- [x] Run the regression and observe the incorrect stop target.
- [x] Scope failure cleanup to the captured channel; preserve original error propagation.
- [x] Run the complete avatar/TTS bridge tests.

### Task 5: Integration, documentation, and delivery

**Files:**
- Modify: README.md
- Modify: docs/FOUNDATION_INTERFACES.zh-CN.md
- Modify: docs/FOUNDATION_OVERVIEW.zh-CN.md
- Create: docs/FOUNDATION_OPTIMIZATION_STATUS.zh-CN.md

- [x] Integrate Task 1 context capture with Task 2's final lifecycle code, avoiding simultaneous edits to the notifier files.
- [x] Record executable test commands, SDK version, baseline failures, actual new behavior, and deferred architecture targets.
- [x] Run formatter, Flutter analyze, and the full foundation-mode test suite; distinguish baseline issues from regressions.
- [x] Perform one independent whole-change review and fix material findings with regression tests.
- [ ] Commit the completed changes on codex/foundation-modular-runtime and create a draft pull request; do not merge main.
