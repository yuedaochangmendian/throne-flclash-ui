import '../common/domain_resolve.dart';
import '../widgets.dart';

/// Resolves domains through the running tunnel's direct DNS (`dns.resolve`).
///
/// The lookups happen in the core process, pinned to `dns-direct`: the OS resolver is what a kill
/// switch blocks, and a running Tun answers it from fakeip, so asking the system would report the
/// tunnel's own fake addresses as the answer. Without a running box there is nothing to ask, and
/// the page says so instead of resolving locally and mislabelling that as the tunnel's answer.
class ResolvePage extends StatefulWidget {
  const ResolvePage({super.key});

  @override State<ResolvePage> createState() => _ResolvePageState();
}

class _ResolvePageState extends State<ResolvePage> {
  final _input = TextEditingController();
  DomainResolveReply? _reply;
  String? _failure;
  bool _busy = false;

  @override void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// One domain per line, and commas, semicolons or spaces between them work as well.
  List<String> get _domains =>
      _input.text.split(RegExp(r'[\s,;]+')).where((value) => value.isNotEmpty).toList();

  Future<void> _resolve() async {
    final domains = _domains;
    if (domains.isEmpty || _busy) return;
    setState(() { _busy = true; _failure = null; });
    try {
      final reply = DomainResolveReply.parse(await context.box.dnsResolve(domains));
      if (!mounted) return;
      setState(() { _reply = reply; _busy = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _failure = BoxController.describe(error); _busy = false; });
    }
  }

  @override Widget build(BuildContext context) {
    final reply = _reply;
    return BoxPage(
      title: 'Domain resolution',
      children: [
        generateSection(items: [
          Padding(padding: const EdgeInsets.all(16), child: TextField(
            controller: _input,
            minLines: 1,
            maxLines: 6,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: context.tr('Domains'),
              hintText: context.tr('One domain per line; commas work too'),
            ),
            onSubmitted: (_) => _resolve(),
          )),
        ], footer: context.tr("Lookups use the tunnel's direct DNS and time out after 5 seconds each.")),
        Padding(padding: const EdgeInsets.symmetric(vertical: 20), child: FilledButton(
          onPressed: _busy || _domains.isEmpty ? null : _resolve,
          child: Text(context.tr(_busy ? 'Resolving' : 'Resolve')),
        )),
        if (_busy) const LinearProgressIndicator(),
        if (_failure != null) Padding(
          padding: const EdgeInsets.only(top: 16),
          child: SelectableText(_failure!, style: TextStyle(color: context.colorScheme.error)),
        ),
        if (reply != null && !reply.running) Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(context.tr('Connect first: lookups run through the running tunnel')),
        ),
        if (reply != null && reply.running) generateSection(
          title: context.tr('Results'),
          items: [
            for (final row in reply.rows) ListItem(
              title: Text(row.domain),
              subtitle: Text(
                row.detail.isEmpty ? context.tr('No address') : row.detail,
                style: row.ok ? null : TextStyle(color: context.colorScheme.error),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
