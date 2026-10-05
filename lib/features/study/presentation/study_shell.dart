import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'statistics_page.dart';
import 'coach_page.dart';
import 'profile_page.dart';
import 'exam_page.dart';

class StudyShell extends ConsumerStatefulWidget {
  const StudyShell({super.key});
  @override
  ConsumerState<StudyShell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<StudyShell> {
  int index = 0;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(studyControllerProvider);
    final notice = ref.watch(studyRefreshNoticeProvider);
    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, stack) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('学习资料暂时无法打开'),
                Text('$error'),
                FilledButton(
                  onPressed: () => ref.invalidate(studyControllerProvider),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (snapshot) => snapshot.exams.any((e) => e['status'] == 'active')
          ? const StudyExamPage()
          : Scaffold(
              body: Column(
                children: [
                  if (notice != null)
                    MaterialBanner(
                      content: Text(notice),
                      actions: [
                        TextButton(
                          onPressed: () => ref
                              .read(studyControllerProvider.notifier)
                              .refresh(),
                          child: const Text('刷新'),
                        ),
                      ],
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: index,
                      children: [
                        const StudyHomePage(),
                        const StudyLibraryPage(),
                        const StudyStatisticsPage(),
                        StudyCoachPage(active: index == 3),
                        const StudyProfilePage(),
                      ],
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: NavigationBar(
                selectedIndex: index,
                onDestinationSelected: (value) => setState(() => index = value),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.today_outlined),
                    label: '今日',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.menu_book_outlined),
                    label: '选词',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.bar_chart_outlined),
                    label: '统计',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.graphic_eq),
                    label: 'AI',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    label: '我的',
                  ),
                ],
              ),
            ),
    );
  }
}
