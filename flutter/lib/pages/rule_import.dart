// The import sheet for a sing-box rule fragment: paste JSON, see what the schema says about it and
// what the importer would add, then commit. Route rules join the profile's list; DNS rules are
// appended to the DNS object, which is where this build keeps `dns.rules`.

import 'dart:async';
import 'dart:convert';

import '../common/singbox_rules.dart';
import '../components/form.dart';
import '../ui/json/engine/json_tree.dart';
import '../widgets.dart';
import 'package:material_ui/material_ui.dart' as material;

/// Imports a sing-box JSON fragment. From a route profile it takes route rules into the profile and
/// DNS rules into the DNS object; from Settings, DNS it takes the DNS rules alone and says where a
/// route rule it finds belongs. Returns true when something was added.
///
/// Opens as the same multiline editor dialog as the rule fields, so importing a
/// JSON fragment and editing a rule value share one visual treatment.
class RuleImportPage extends StatefulWidget {
  const RuleImportPage({super.key, this.profileId, this.intoPool = false});

  /// The route profile the route rules join; null is the DNS page's own sheet.
  final int? profileId;

  /// When true route rules join the shared global pool instead of a profile.
  final bool intoPool;

  @override State<RuleImportPage> createState() => _RuleImportPageState();
}

/// The parsed fragment handed back to the page that opened the import dialog.
class RuleImportRequest {
  const RuleImportRequest(this.result);
  final RuleImportResult result;
}

Future<void> applyRuleImport(BoxController box, RuleImportRequest request, {int? profileId, bool intoPool = false}) async {
  final result = request.result;
  if (intoPool && result.routeRules.isNotEmpty) {
    final existing = json(await box.routeGlobalRules(0));
    final rules = [...rows(existing['rules']), ...result.routeRules];
    await box.routeSaveGlobalRules(rules);
  } else if (profileId != null && result.routeRules.isNotEmpty) {
    final existing = json(await box.routeRules(profileId));
    final rules = [...rows(existing['rules']), ...result.routeRules];
    await box.routeSaveRules(profileId, rules);
  }
  if (result.dnsRules.isNotEmpty) {
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
    dns['rules'] = [if (existing is List) ...existing, ...result.dnsRules];
    await box.setSetting('dnsObject', jsonEncode(dns));
  }
}

class _RuleImportPageState extends State<RuleImportPage> {
  String _input = '';
  Timer? _debounce;
  RuleImportResult? _result;
  Map<String, int> _outboundIds = const {};

  /// The DNS page has no profile to add route rules to, so it only ever reads `dns.rules`.
  bool get _dnsOnly => widget.profileId == null;

  /// A completely ambiguous bare rule follows the page it was opened from; rules with route or
  /// DNS-specific members are classified by the importer itself.
  RuleImportKind get _fallbackKind => _dnsOnly ? RuleImportKind.dns : RuleImportKind.route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// The server tags a rule may name as its outbound; a dead service only leaves them unresolvable,
  /// which the preview then reports per rule instead of failing the whole import. The DNS sheet
  /// never converts route rules, so it asks for nothing.
  Future<void> _load() async {
    if (_dnsOnly) return;
    try {
      final nodes = await context.box.groupNodes();
      if (!mounted) return;
      setState(() => _outboundIds = {
        for (final node in nodes)
          if ('${node['tag'] ?? ''}'.isNotEmpty) '${node['tag']}': (node['id'] as num?)?.toInt() ?? 0,
      });
    } catch (_) {}
  }

  void _changed(String value) {
    _input = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _parse);
  }

  Future<void> _parse() async {
    final text = _input.trim();
    if (text.isEmpty) {
      if (mounted) setState(() { _result = null; });
      return;
    }
    final result = await RuleImporter(outboundIds: _outboundIds).run(text, kind: _fallbackKind);
    if (!mounted) return;
    setState(() {
      _result = result;
    });
  }

  bool get _canImport {
    final result = _result;
    if (result == null || result.error != null) return false;
    return _dnsOnly ? result.dnsRules.isNotEmpty : result.total > 0;
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return material.Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 600, maxHeight: MediaQuery.sizeOf(context).height * .82),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(context.tr(_dnsOnly ? 'Import DNS rules' : 'Import rules from JSON'),
              style: AppTextStyle.title3.of(context, emphasized: true)),
            const SizedBox(height: 12),
            Flexible(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(context.tr('Paste a sing-box fragment carrying route or DNS rules; both are recognised automatically and checked against the schema first.'),
                  style: AppTextStyle.caption1.of(context)),
                const SizedBox(height: 10),
                SizedBox(height: 210, child: TextField(
                  key: const Key('rule-import-field'),
                  expands: true, minLines: null, maxLines: null,
                  keyboardType: TextInputType.multiline, textAlignVertical: TextAlignVertical.top,
                  autocorrect: false, onChanged: _changed,
                  style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
                  decoration: const InputDecoration(border: OutlineInputBorder(),
                    isDense: true, contentPadding: EdgeInsets.fromLTRB(12, 12, 12, 12)),
                )),
                if (result != null) ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150), child: _summary(result)),
              ])),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
              TextButton(
                onPressed: _canImport ? () => Navigator.pop(context, RuleImportRequest(result!)) : null,
                child: Text(context.tr('Import')),
              ),
            ]),
          ]),
        ),
      ),
    );
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
          if (_dnsOnly) ...[
            // Said out loud rather than dropped: these rules are real, they just live elsewhere.
            if (result.routeRules.isNotEmpty) ListItem(
              leading: GlyphIcon(AppGlyphs.info, color: context.colorScheme.tertiary),
              title: Text(context.tr('Route rules belong to a route profile')),
              subtitle: Text(context.tr('Open a route profile to import those.')),
              trailing: Text('${result.routeRules.length}', style: context.listValueStyle),
            ),
            ListItem(
              leading: const GlyphIcon(AppGlyphs.dns),
              title: Text(context.tr('DNS rules to add')),
              trailing: Text('${result.dnsRules.length}', style: context.listValueStyle),
            ),
          ] else ...[
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
          ],
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
