import 'package:ai_secretary/services/call_foreground_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  Future<void> nativeEvent(String method) async {
    await messenger.handlePlatformMessage(
      'com.namson.ai_secretary/call',
      codec.encodeMethodCall(MethodCall(method)),
      null,
    );
  }

  // Function.apply lets the regression run against the legacy void return type.
  void Function() stopSubscription(Future<void> Function() callback) {
    final unsubscribe = Function.apply(CallForegroundService.onStopRequested, [
      callback,
    ]);
    expect(unsubscribe, isA<void Function()>());
    return unsubscribe as void Function();
  }

  void Function() returnSubscription(void Function() callback) {
    final unsubscribe = Function.apply(
      CallForegroundService.onReturnRequested,
      [callback],
    );
    expect(unsubscribe, isA<void Function()>());
    return unsubscribe as void Function();
  }

  test(
    'native stop subscription stops receiving events after unsubscribe',
    () async {
      var calls = 0;
      final unsubscribe = stopSubscription(() async => calls++);
      addTearDown(unsubscribe);

      await nativeEvent('stopRequested');
      unsubscribe();
      await nativeEvent('stopRequested');

      expect(calls, 1);
    },
  );

  test('an old stop owner cannot unsubscribe the replacement owner', () async {
    var oldCalls = 0;
    var currentCalls = 0;
    final removeOld = stopSubscription(() async => oldCalls++);
    final removeCurrent = stopSubscription(() async => currentCalls++);
    addTearDown(removeCurrent);

    removeOld();
    await nativeEvent('stopRequested');

    expect(oldCalls, 0);
    expect(currentCalls, 1);
  });

  test(
    'registering the same callback twice still creates distinct ownership',
    () async {
      var calls = 0;
      Future<void> callback() async => calls++;
      final removeOld = stopSubscription(callback);
      final removeCurrent = stopSubscription(callback);
      addTearDown(removeCurrent);

      removeOld();
      await nativeEvent('stopRequested');

      expect(calls, 1);
    },
  );

  test(
    'return subscriptions keep the latest owner and detach on disposal',
    () async {
      var oldCalls = 0;
      var currentCalls = 0;
      final removeOld = returnSubscription(() => oldCalls++);
      final removeCurrent = returnSubscription(() => currentCalls++);
      addTearDown(removeCurrent);

      removeOld();
      await nativeEvent('openRequested');
      removeCurrent();
      await nativeEvent('openRequested');

      expect(oldCalls, 0);
      expect(currentCalls, 1);
    },
  );
}
