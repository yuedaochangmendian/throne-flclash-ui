// The import sheet for a sing-box rule fragment: paste JSON, see what the schema says about it and
// what the importer would add, then commit. Route rules join the profile's list; DNS rules are
// appended to the DNS object, which is where this build keeps `dns.rules`.

import 'dart:async';
import 'dart:convert';

import '../common/singbox_rules.dart';
import '../components/code_editor.dart';
import '../components/form.dart';
import '../ui/json/engine/json_tree.dart';
import '../widgets.dart';

/// Imports a sing-box JSON fragment into route profile [profileId]. Returns true when something was
/// added, so the profile editor reloads its rules.
class RuleImportPage extends StatefulWidget {
  const RuleImportPage({super.key, required this.profileId});
  final int profileId;
  @override State<RuleImportPage> createState() => _RuleImportPageState();
}

class _RuleImportPageState extends State<RuleImportPage> {
  final _text = JsonCodeController();
  final _undo = UndoHistoryController();
  Timer? _debounce;
  RuleImportKind _kind = RuleImportKind.route;
  RuleImportResult? _result;
  Map<String, int> _outboundIds = const {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.removeListener(_changed);
    _text.dispose();
    _undo.dispose();
    super.dispose();
  }

  /// The server tags a rule may name as its outbound; a dead service only leaves them unresolvable,
  /// which the preview then reports per rule instead of failing the whole import.
  Future<void> _load() async {
    try {
      final nodes = await context.box.groupNodes();
      if (!mounted) return;
      setState(() => _outboundIds = {
        for (final node in nodes)
          if ('${node['tag'] ?? ''}'.isNotEmpty) '${node['tag']}': (node['id'] as num?)?.toInt() ?? 0,
      });
    } catch (_) {}
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _parse);
  }

  Future<void> _parse() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      if (mounted) setState(() { _result = null; _text.issues = const []; });
      return;
    }
    final result = await RuleImporter(outboundIds: _outboundIds).run(text, kind: _kind);
    if (!mounted) return;
    setState(() {
      _result = result;
      _text.issues = result.issues;
    });
  }

  bool get _canImport {
    final result = _result;
    return !_saving && result != null && result.error == null && result.total > 0;
  }

  Future<void> _import() async {
    final result = _result;
    if (result == null || !_canImport) return;
    final box = context.box;
    setState(() { _saving = true; _error = null; });
    try {
      if (result.routeRules.isNotEmpty) {
        final existing = json(await box.routeRules(widget.profileId));
        final rules = [...rows(existing['rules']), ...result.routeRules];
        await box.routeSaveRules(widget.profileId, rules);
      }
      if (result.dnsRules.isNotEmpty) await _appendDnsRules(box, result.dnsRules);
      if (mounted) context.safeNestedPop(true);
    } catch (error) {
      if (mounted) setState(() { _saving = false; _error = BoxController.describe(error); });
    }
  }

  /// Appends to the DNS object's `rules`. The object is the only place this build keeps `dns.rules`,
  /// so a profile has no DNS rule list of its own; the page says so when the object is switched off.
  Future<void> _appendDnsRules(BoxController box, List<Map<String, dynamic>> rules) async {
    final raw = (box.settings['dnsObject'] ?? '').toString().trim();
    var dns = <String, dynamic>{};
    if (raw.isNotEmpty) {
      final parsed = JsonTree.parse(raw);
      final plain = parsed.root == null ? null : JsonTree.toPlain(parsed.root!);
      if (plain is! Map) {
        throw StateError('The DNS object is not a JSON object; fix it in Settings, DNS first');
      }
      dns = Map<String, dynamic>.from(plain);
    }
    final existing = dns['rules'];
    dns['rules'] = [
      if (existing is List) ...existing,
      ...rules,
    ];
    await box.setSetting('dnsObject', jsonEncode(dns));
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      title: context.tr('Import rules'),
      isLoading: _saving,
      confirmationAction: IconButtonData(
        glyph: AppGlyphs.check, tooltip: context.tr('Import'),
        onPressed: _canImport ? _import : null,
      ),
      body: Padding(
        padding: EdgeInsets.only(top: context.appBarInset),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          generateSection(items: [
            ListItem(
              title: Text(context.tr('Rule kind')),
              subtitle: Text(context.tr(
                'Used for a bare rule or a bare "rules" array; a fragment with "route" or "dns" says it itself.')),
              trailing: Text(context.tr(_kind == RuleImportKind.dns ? 'DNS' : 'Route'),
                style: context.listValueStyle),
              onTap: _pickKind,
            ),
          ]),
          if (_error != null) Container(
            width: double.infinity, padding: const EdgeInsets.all(12),
            color: context.colorScheme.errorContainer,
            child: SelectableText(_error!, style: TextStyle(color: context.colorScheme.onErrorContainer))),
          JsonIssuesStrip(issues: _text.issues, text: _text.text, controller: _text),
          Expanded(child: CodeEditor(controller: _text, undoController: _undo)),
          _summary(result),
        ]),
      ),
    );
  }

  Future<void> _pickKind() async {
    final picked = await showDialog<RuleImportKind>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.tr('Rule kind'), style: AppTextStyle.title3.of(context, emphasized: true)),
        children: [
          for (final (value, label) in [
            (RuleImportKind.route, 'Route'), (RuleImportKind.dns, 'DNS'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, value),
              child: Text(context.tr(label), style: AppTextStyle.body.of(context)),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _kind = picked);
    await _parse();
  }

  /// The preview: what the import would add, what it would leave out, and why.
  Widget _summary(RuleImportResult? result) {
    final problems = result?.problems ?? const <RuleImportProblem>[];
    final usesDns = (result?.dnsRules.isNotEmpty ?? false) && context.box.settings['useDnsObject'] != true;
    final rows = <Widget>[
      if (result == null) ListItem(
        leading: const GlyphIcon(AppGlyphs.info),
        title: Text(context.tr('Paste a sing-box rule fragment')),
        subtitle: Text(context.tr(
          'A rule, an array of rules, {"rules": [...]}, or a config carrying "route" and "dns".')),
      ) else ...[
        if (result.error != null) ListItem(
          leading: GlyphIcon(AppGlyphs.warning, color: context.colorScheme.error),
          title: Text(context.tr('Not a rule fragment')),
          subtitle: Text(result.error!),
        ) else ...[
          ListItem(
            leading: const GlyphIcon(AppGlyphs.check),
            title: Text(context.tr('Route rules to add')),
            trailing: Text('${result.routeRules.length}', style: context.listValueStyle),
          ),
          ListItem(
            leading: const GlyphIcon(AppGlyphs.dns),
            title: Text(context.tr('DNS rules to add')),
            trailing: Text('${result.dnsRules.length}', style: context.listValueStyle),
          ),
          if (usesDns) ListItem(
            leading: GlyphIcon(AppGlyphs.info, color: context.colorScheme.tertiary),
            title: Text(context.tr('DNS rules wait for the DNS object')),
            subtitle: Text(context.tr(
              'They are stored in the DNS object, which Settings, DNS has switched off; turn it on for them to apply.')),
          ),
          if (result.hasErrors) ListItem(
            leading: GlyphIcon(AppGlyphs.warning, color: context.colorScheme.error),
            title: Text(context.tr('The schema rejects part of this fragment')),
            subtitle: Text(context.tr('Fix the underlined fields before importing.')),
          ),
          for (final problem in problems.take(20)) ListItem(
            leading: GlyphIcon(AppGlyphs.warning, color: const Color(0xfff08c00)),
            title: Text(problem.rule),
            subtitle: Text(problem.reason),
          ),
        ],
      ],
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: Material(
        color: context.colorScheme.surfaceContainerLow,
        child: ListView(shrinkWrap: true, children: rows),
      ),
    );
  }
}
