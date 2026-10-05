import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import '../domain/study_models.dart';
import '../domain/study_service.dart';
import 'learning_page.dart';
import 'study_widgets.dart';

class StudyLibraryPage extends ConsumerStatefulWidget {
  const StudyLibraryPage({super.key});
  @override
  ConsumerState<StudyLibraryPage> createState() => _LibraryState();
}

class _LibraryState extends ConsumerState<StudyLibraryPage> {
  String query = '', filter = '全部';
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(studyControllerProvider).asData?.value;
    final catalog = ref.watch(studyCatalogProvider).asData?.value;
    if (state == null || catalog == null) return const SizedBox.shrink();
    final selected = state.progress.values.where((p) => p.selected).toList();
    final items = selected
        .where(
          (p) =>
              filter == '全部' ||
              filter == '暂停' && p.disposition == WordDisposition.paused ||
              filter == '熟知' && p.disposition == WordDisposition.familiar ||
              filter == '收藏' && p.favorite ||
              filter == '巩固' &&
                  p.introduced &&
                  p.disposition == WordDisposition.active,
        )
        .map((p) => catalog.words[p.wordId])
        .whereType<StudyWord>()
        .where(
          (w) =>
              w.word.contains(query.toLowerCase()) || w.meaning.contains(query),
        )
        .toList();
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '选词',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${selected.length} 已选',
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ),
          const StudySection('内置词书'),
          ...catalog.books.map(
            (b) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Container(
                width: 42,
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: studyTeal.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.menu_book, color: studyTeal),
              ),
              title: Text(b.title),
              subtitle: Text(
                '${b.wordIds.length} 词 · ${b.subtitle}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final receipt = await studyCommit(
                  context,
                  ref,
                  (r) => r.updatePreferences(studyCommandId(), {
                    'bookId': b.id,
                  }, expectedRevision: state.preferences.revision),
                );
                if (receipt != null && context.mounted) {
                  studyOpen(context, StudyBookPage(bookId: b.id));
                }
              },
            ),
          ),
          const StudySection('我的已选词'),
          TextField(
            decoration: const InputDecoration(
              hintText: '搜索已选单词或释义',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => query = v),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            children: ['全部', '巩固', '熟知', '暂停', '收藏']
                .map(
                  (s) => ChoiceChip(
                    label: Text(s),
                    selected: filter == s,
                    onSelected: (_) => setState(() => filter = s),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 14),
          ...items
              .take(80)
              .map(
                (w) => _WordRow(
                  word: w,
                  progress: state.progress[w.id],
                  onOpen: () => _showWord(context, ref, w, state),
                ),
              ),
          if (items.length > 80) Text('${items.length} 个结果，仅显示前80项；请输入单词缩小范围。'),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => _importMaterial(context, ref, catalog),
            icon: const Icon(Icons.article_outlined),
            label: const Text('从个人短文选词'),
          ),
          const Text(
            '词书共享同一单词学习记录。来源：ECDICT / MIT；核心精选，不是完整考试大纲。',
            style: TextStyle(fontSize: 12, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

class StudyBookPage extends ConsumerStatefulWidget {
  const StudyBookPage({super.key, required this.bookId});
  final String bookId;
  @override
  ConsumerState<StudyBookPage> createState() => _BookState();
}

class _BookState extends ConsumerState<StudyBookPage> {
  String query = '', tab = '未选', letter = 'A';
  int page = 0;
  final draft = <String>{};
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(studyControllerProvider).asData?.value;
    final catalog = ref.watch(studyCatalogProvider).asData?.value;
    if (state == null || catalog == null) return const SizedBox.shrink();
    final book = catalog.books.firstWhere((b) => b.id == widget.bookId);
    final selected = state.progress.values
        .where((p) => p.selected)
        .map((p) => p.wordId)
        .toSet();
    final all = book.wordIds.map((id) => catalog.words[id]!).toList();
    final selectedCount = book.wordIds.where(selected.contains).length;
    var rows = all
        .where(
          (w) => tab == '已选'
              ? selected.contains(w.id)
              : tab == '未选'
              ? !selected.contains(w.id)
              : true,
        )
        .where(
          (w) =>
              w.word.contains(query.toLowerCase()) || w.meaning.contains(query),
        )
        .toList();
    final letters = rows.map((w) => w.word[0].toUpperCase()).toSet().toList()
      ..sort();
    final activeLetter = letters.contains(letter)
        ? letter
        : letters.firstOrNull;
    if (tab == '字母索引') {
      rows = rows
          .where((w) => w.word[0].toUpperCase() == activeLetter)
          .toList();
    }
    final pages = max(1, (rows.length / 40).ceil());
    final currentPage = min(page, pages - 1);
    final visible = rows.skip(currentPage * 40).take(40).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(book.title),
        actions: [
          IconButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('词库来源'),
                content: Text(
                  '${book.subtitle}\n\n固定版ECDICT开源词典，MIT许可。释义与音标保留来源；核心精选不宣称完整考试大纲。例句标界面示例的内容独立编写，缺项保持缺项。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('知道了'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: TextField(
              decoration: const InputDecoration(
                hintText: '搜索整本词书',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() {
                query = v;
                page = 0;
              }),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: ['未选', '已选', '全部', '字母索引']
                  .map(
                    (s) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(
                          s == '未选'
                              ? '未选 ${all.length - selectedCount}'
                              : s == '已选'
                              ? '已选 $selectedCount'
                              : s == '全部'
                              ? '全部 ${all.length}'
                              : s,
                        ),
                        selected: tab == s,
                        onSelected: (_) => setState(() {
                          tab = s;
                          page = 0;
                        }),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          if (tab == '字母索引')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  const Text('字母分组 '),
                  DropdownButton<String>(
                    value: activeLetter,
                    items: letters
                        .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                        .toList(),
                    onChanged: (v) => setState(() {
                      letter = v ?? 'A';
                      page = 0;
                    }),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: rows.isEmpty
                        ? null
                        : () => setState(
                            () => draft.addAll(
                              rows
                                  .where((w) => !selected.contains(w.id))
                                  .map((w) => w.id),
                            ),
                          ),
                    child: Text(
                      '勾选搜索内本组 ${rows.where((w) => !selected.contains(w.id)).length}',
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: visible.length,
              itemBuilder: (context, i) {
                final w = visible[i];
                final saved = selected.contains(w.id);
                return ListTile(
                  leading: Checkbox(
                    value: saved || draft.contains(w.id),
                    onChanged: saved
                        ? null
                        : (v) => setState(
                            () => v == true
                                ? draft.add(w.id)
                                : draft.remove(w.id),
                          ),
                  ),
                  title: Text(w.word),
                  subtitle: Text(
                    w.meaning,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => _showWord(context, ref, w, state),
                  ),
                );
              },
            ),
          ),
          if (pages > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: currentPage > 0
                      ? () => setState(() => page = currentPage - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('${currentPage + 1} / $pages · ${rows.length} 词'),
                IconButton(
                  onPressed: currentPage < pages - 1
                      ? () => setState(() => page = currentPage + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => _pick(
                          rows,
                          selected,
                          state.preferences.newLimit,
                          false,
                        ),
                        child: Text('顺选 ${state.preferences.newLimit}'),
                      ),
                      TextButton(
                        onPressed: () => _pick(
                          rows,
                          selected,
                          state.preferences.newLimit,
                          true,
                        ),
                        child: const Text('随机选词'),
                      ),
                      TextButton(
                        onPressed: () => setState(draft.clear),
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: draft.isEmpty
                          ? null
                          : () async {
                              final receipt = await studyCommit(
                                context,
                                ref,
                                (r) => r.selectWords(
                                  studyCommandId(),
                                  draft.toList(),
                                ),
                              );
                              if (receipt != null && mounted) {
                                setState(draft.clear);
                              }
                            },
                      child: Text('确认加入 ${draft.length} 个词'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _pick(
    List<StudyWord> words,
    Set<String> selected,
    int amount,
    bool random,
  ) {
    final pool = words
        .where((w) => !selected.contains(w.id) && !draft.contains(w.id))
        .toList();
    if (random) pool.shuffle();
    setState(
      () => draft.addAll(
        pool.take(max(0, amount - draft.length)).map((w) => w.id),
      ),
    );
  }
}

class _WordRow extends StatelessWidget {
  const _WordRow({
    required this.word,
    required this.progress,
    required this.onOpen,
  });
  final StudyWord word;
  final WordProgress? progress;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(word.word),
    subtitle: Text(
      '${word.ipa}\n${word.meaning}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Text(
      progress?.disposition == WordDisposition.paused
          ? '暂停'
          : progress?.disposition == WordDisposition.familiar
          ? '熟知'
          : progress?.introduced == true
          ? '已练'
          : '未练',
      style: const TextStyle(color: Colors.white54, fontSize: 12),
    ),
    onTap: onOpen,
  );
}

void _showWord(
  BuildContext context,
  WidgetRef ref,
  StudyWord word,
  StudySnapshot state,
) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              word.word,
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
            ),
            Text(word.ipa, style: const TextStyle(color: Colors.white54)),
            const SizedBox(height: 18),
            Text(word.meaning),
            if (word.example.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(word.example),
              Text(
                word.translation,
                style: const TextStyle(color: Colors.white54),
              ),
              Text(
                '例句：${word.exampleSource}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ] else
              const Text(
                '\n暂无例句，可添加个人笔记。',
                style: TextStyle(color: Colors.white54),
              ),
            if ((state.progress[word.id]?.note ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('个人笔记：${state.progress[word.id]!.note}'),
              ),
            Text(
              '释义：${word.source}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () async {
                    await studyCommit(
                      context,
                      ref,
                      (r) => r.updateWord(
                        studyCommandId(),
                        word.id,
                        disposition: WordDisposition.familiar,
                      ),
                    );
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                  child: const Text('标熟知'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    await studyCommit(
                      context,
                      ref,
                      (r) => r.updateWord(
                        studyCommandId(),
                        word.id,
                        disposition:
                            state.progress[word.id]?.disposition ==
                                WordDisposition.paused
                            ? WordDisposition.active
                            : WordDisposition.paused,
                      ),
                    );
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                  child: Text(
                    state.progress[word.id]?.disposition ==
                            WordDisposition.paused
                        ? '恢复'
                        : '暂停',
                  ),
                ),
                OutlinedButton(
                  onPressed: () async {
                    await studyCommit(
                      context,
                      ref,
                      (r) => r.updateWord(
                        studyCommandId(),
                        word.id,
                        favorite: !(state.progress[word.id]?.favorite ?? false),
                      ),
                    );
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                  child: const Text('收藏'),
                ),
                OutlinedButton(
                  onPressed: () => _editNote(
                    sheetContext,
                    ref,
                    word,
                    state.progress[word.id]?.note ?? '',
                  ),
                  child: const Text('个人笔记'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  if (state.progress[word.id]?.selected != true) {
                    await studyCommit(
                      context,
                      ref,
                      (r) => r.selectWords(studyCommandId(), [word.id]),
                    );
                  }
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (context.mounted) {
                    studyOpen(
                      context,
                      StudyLearningPage(
                        tasks: [
                          StudyTask(
                            word.id,
                            state.preferences.direction == 'cn-en'
                                ? StudySkill.production
                                : StudySkill.meaning,
                          ),
                        ],
                      ),
                    );
                  }
                },
                child: Text(
                  state.progress[word.id]?.selected == true
                      ? '开始独立练习'
                      : '选入此词并练习',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _importMaterial(
  BuildContext context,
  WidgetRef ref,
  StudyCatalog catalog,
) async {
  final text = await showDialog<String>(
    context: context,
    builder: (_) => const StudyTextDialog(
      title: '从个人短文选词',
      hint: '粘贴英文，仅在本机匹配单词，不上传短文',
      confirm: '确认加入匹配词',
      maxLines: 5,
      maxLength: 20000,
    ),
  );
  if (text == null || !context.mounted) return;
  final tokens = RegExp(
    r"[a-z]+(?:['-][a-z]+)*",
  ).allMatches(text.toLowerCase()).map((m) => m.group(0)!).toSet();
  final ids = tokens.where(catalog.words.containsKey).toList();
  if (ids.isEmpty) {
    studyMessage(context, '没有匹配的词条，不伪造释义。');
    return;
  }
  await studyCommit(context, ref, (r) => r.selectWords(studyCommandId(), ids));
}

Future<void> _editNote(
  BuildContext context,
  WidgetRef ref,
  StudyWord word,
  String previous,
) async {
  final text = await showDialog<String>(
    context: context,
    builder: (_) => StudyTextDialog(
      title: '${word.word} · 个人笔记',
      hint: '自己的例句、联想或学习提醒',
      confirm: '保存笔记',
      initial: previous,
      maxLines: 4,
      maxLength: 2000,
    ),
  );
  if (text == null || !context.mounted) return;
  await studyCommit(
    context,
    ref,
    (r) => r.updateWord(studyCommandId(), word.id, note: text),
  );
}
