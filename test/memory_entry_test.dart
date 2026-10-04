import 'package:ai_secretary/models/memory_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'copyWith can explicitly clear nullable confirmation and expiry fields',
    () {
      final now = DateTime(2026, 6, 30, 12);
      final entry = MemoryEntry(
        key: 'temporary_plan',
        value: '今晚练背',
        lastConfirmedAt: now,
        expiresAt: now.add(const Duration(hours: 2)),
        createdAt: now,
      );

      final updated = entry.copyWith(
        value: '明早练背',
        clearLastConfirmedAt: true,
        clearExpiresAt: true,
      );

      expect(updated.value, '明早练背');
      expect(updated.lastConfirmedAt, isNull);
      expect(updated.expiresAt, isNull);
      expect(updated.createdAt, now);
    },
  );

  test(
    'copyWith preserves nullable confirmation and expiry fields by default',
    () {
      final now = DateTime(2026, 6, 30, 12);
      final expiry = now.add(const Duration(hours: 2));
      final entry = MemoryEntry(
        key: 'temporary_plan',
        value: '今晚练背',
        lastConfirmedAt: now,
        expiresAt: expiry,
        createdAt: now,
      );

      final updated = entry.copyWith(value: '今晚练肩');

      expect(updated.value, '今晚练肩');
      expect(updated.lastConfirmedAt, now);
      expect(updated.expiresAt, expiry);
    },
  );
}
