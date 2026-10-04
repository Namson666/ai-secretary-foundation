import 'package:ai_secretary/core/app_edition.dart';
import 'package:ai_secretary/foundation_app.dart';
import 'package:ai_secretary/providers/digital_human_provider.dart';
import 'package:ai_secretary/features/settings/screens/foundation_settings_screen.dart';
import 'package:ai_secretary/features/digital_human/screens/home_screen.dart';
import 'package:ai_secretary/features/digital_human/widgets/duix_avatar_view.dart';
import 'package:ai_secretary/providers/assistant_modules_provider.dart';
import 'package:ai_secretary/providers/settings_provider.dart';
import 'package:ai_secretary/shared/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _IdleAvatar extends DigitalHumanNotifier {
  @override
  DigitalHumanState build() => const DigitalHumanState();

  @override
  Future<void> resumeCallIfNeeded() async {}
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('base registry contains only reusable search', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(assistantModuleRegistryProvider).modules.map((m) => m.id),
      ['web_search'],
    );
  });

  test(
    'foundation edition has no health professions',
    skip: !AppEdition.isFoundation,
    () {
      expect(SettingsState.foundationInitial.professions, isEmpty);
    },
  );

  testWidgets(
    'foundation settings contain no health configuration',
    skip: !AppEdition.isFoundation,
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: FoundationSettingsScreen(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('基础设置'), findsOneWidget);
      expect(find.text('语音识别'), findsOneWidget);
      expect(find.text('回复音色'), findsOneWidget);
      expect(find.text('职业身份设置'), findsNothing);
      expect(find.text('用户档案'), findsNothing);
    },
  );

  testWidgets('foundation settings route has a visible viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [digitalHumanProvider.overrideWith(_IdleAvatar.new)],
    );
    addTearDown(container.dispose);
    final router = container.read(foundationRouterProvider);
    router.go('/settings');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.darkTheme,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byType(FoundationSettingsScreen)).height,
      greaterThan(400),
    );
    expect(find.byType(DuixAvatarView, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('foundation navigation removes the avatar on settings', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [digitalHumanProvider.overrideWith(_IdleAvatar.new)],
    );
    addTearDown(container.dispose);
    final router = container.read(foundationRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.darkTheme,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(HomeScreen), findsOneWidget);
    router.go('/settings');
    await tester.pump();
    expect(find.byType(HomeScreen, skipOffstage: false), findsNothing);
    expect(find.byType(FoundationSettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
