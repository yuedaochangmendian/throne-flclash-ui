import 'package:super_sliver_list/super_sliver_list.dart';
import '../widgets.dart';
import '../common/log_payload.dart';
import '../components/record.dart';
import '../components/data_subscription.dart';

/// FlClash's log view, carried over as-is: one export action, an empty state, a scrollbar that
/// names the record at the thumb, and a list that follows the newest line until the reader
/// scrolls away from it. The records themselves are rendered by [_LogItem] / [_LogBody], which
/// keep FlClash's shape and parse this fork's sing-box / Xray lines instead of mihomo's.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});
  @override State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String _query = '';
  // Labels tapped on a record filter by them; the search field keeps its own text.
  final _keywords = ValueNotifier<List<ScaffoldKeyword>>(const []);
  bool _exporting = false;
  /// The records frozen when the reader scrolled away from the newest line; null while following.
  List<Json>? _paused;
  late final _scroll = ScrollController(initialScrollOffset: double.maxFinite);
  late final _physics = FollowEndScrollPhysics(isFollowing: () => _paused == null);

  String get _search => [
    _query,
    ..._keywords.value.map((keyword) => '${keyword.key}'),
  ].where((word) => word.trim().isNotEmpty).join(' ');

  @override void initState() {
    super.initState();
    _keywords.addListener(_keywordsChanged);
  }

  @override void dispose() {
    _keywords.removeListener(_keywordsChanged);
    _keywords.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _keywordsChanged() => setState(() {});

  void _addFilter(String word) {
    if (_keywords.value.any((keyword) => keyword.key == word)) return;
    _keywords.value = [..._keywords.value, ScaffoldKeyword(key: word, label: word, onDeleted: () => _removeFilter(word))];
  }

  void _removeFilter(String word) =>
    _keywords.value = [for (final keyword in _keywords.value) if (keyword.key != word) keyword];

  void _pause() {
    if (_paused == null) setState(() => _paused = List.of(context.box.logs));
  }

  void _resume() {
    if (_paused != null) setState(() => _paused = null);
  }

  Future<void> _export(List<Json> logs) async {
    if (_exporting || logs.isEmpty) return;
    final box = context.box;
    setState(() => _exporting = true);
    try {
      // Log lines carry URLs and keys; the bridge redacts like the native export.
      final saved = await box.documentSave('B-box.log',
        logs.map((line) => '${recordTime(line['receivedAt'])} [${line['level']}] ${line['message']}').join('\n'), redact: true);
      // A cancelled system picker is neither an export nor an error.
      if (mounted && saved != null) box.showMessage(context.tr(saved == true ? 'Exported' : 'Export failed'));
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override Widget build(BuildContext context) {
    final box = context.watchBox(BoxAspect.logs);
    final words = _search.toLowerCase().trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final logs = (_paused ?? box.logs).where((item) =>
      words.every((word) => [item['level'], item['message']].join(' ').toLowerCase().contains(word)),
    ).toList();
    return BoxDataSubscription(data: BoxData.logs, child: Scaffold(
      title: context.tr('Logs'),
      keywords: _keywords,
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      iconActions: [
        IconButtonData(glyph: AppGlyphs.export, tooltip: context.tr('Export'),
          onPressed: logs.isEmpty || _exporting ? null : () => _export(logs)),
      ],
      body: NullStatusSwitcher(
        isEmpty: logs.isEmpty,
        isSearching: _search.trim().isNotEmpty,
        nullStatus: NullStatus(label: context.tr('No logs'), illustration: NullStatusIllustration.logs),
        child: logs.isEmpty ? const SizedBox.shrink() : Align(
          alignment: Alignment.topCenter,
          child: FloatingScrollbar(
            controller: _scroll,
            hintBuilder: (fraction) => recordTime(logs[(fraction * (logs.length - 1)).round()]['receivedAt']),
            child: ScrollToEndBox(
              controller: _scroll, enable: _paused == null,
              onCancelToEnd: _pause, onResumeToEnd: _resume,
              child: SuperListView.separated(
                controller: _scroll, physics: _physics, reverse: true, shrinkWrap: true,
                // The body starts at the top of the window with the app bar floating over it.
                padding: EdgeInsets.only(top: context.contentTopPadding, bottom: 16 + context.bottomInset),
                extentEstimation: recordListExtentEstimation,
                itemCount: logs.length,
                separatorBuilder: (_, _) => const SizedBox(height: recordListGap),
                itemBuilder: (context, index) => _LogItem(log: logs[index], onLabel: _addFilter),
              ),
            ),
          ),
        ),
      ),
    ));
  }
}

class _LogItem extends StatelessWidget {
  const _LogItem({required this.log, required this.onLabel});

  final Json log;
  final ValueChanged<String> onLabel;

  @override Widget build(BuildContext context) {
    final level = log['level'].toString().toLowerCase();
    final tone = switch (level) {
      'warn' || 'warning' => RecordTone.warning,
      'error' || 'fatal' || 'panic' => RecordTone.error,
      _ => RecordTone.neutral,
    };
    return RecordListItem(
      key: ValueKey(log['id']),
      onTap: () {},
      header: RecordHeader(children: [
        if ((log['receivedAt'] as num? ?? 0) > 0) RecordTimestamp(recordTime(log['receivedAt'])),
        RecordLabel(label: level, tone: tone, onPressed: () => onLabel(level)),
      ]),
      body: _LogBody(payload: LogPayload.parse(log['message'].toString())),
    );
  }
}

class _LogBody extends StatelessWidget {
  const _LogBody({required this.payload});

  final LogPayload payload;

  @override Widget build(BuildContext context) {
    final styles = RecordTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(payload.message, style: styles.primary),
        if (payload.source.isNotEmpty) Text(payload.source, style: styles.secondary),
      ],
    );
  }
}
