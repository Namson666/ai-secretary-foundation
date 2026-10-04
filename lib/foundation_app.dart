import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/digital_human/screens/home_screen.dart';
import 'features/settings/screens/foundation_settings_screen.dart';
import 'providers/digital_human_provider.dart';
import 'services/call_foreground_service.dart';
import 'shared/theme/app_theme.dart';
import 'shared/call_status_banner.dart';

final foundationRouterProvider = Provider<GoRouter>(
  (ref) => GoRouter(
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          final home = state.uri.path == '/';
          return Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                if (home) const HomeScreen(bottomBarHeight: 0) else child,
                if (!home) const CallStatusBanner(),
              ],
            ),
          );
        },
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
          GoRoute(
            path: '/settings',
            builder: (_, _) => const FoundationSettingsScreen(),
          ),
        ],
      ),
    ],
  ),
);

class FoundationApp extends ConsumerStatefulWidget {
  const FoundationApp({super.key});

  @override
  ConsumerState<FoundationApp> createState() => _FoundationAppState();
}

class _FoundationAppState extends ConsumerState<FoundationApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CallForegroundService.onReturnRequested(() {
      if (mounted) ref.read(foundationRouterProvider).go('/');
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(digitalHumanProvider.notifier).resumeCallIfNeeded();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(digitalHumanProvider, (_, _) {});
    return MaterialApp.router(
      title: '数字人底座',
      theme: AppTheme.darkTheme,
      routerConfig: ref.watch(foundationRouterProvider),
      debugShowCheckedModeBanner: false,
    );
  }
}
