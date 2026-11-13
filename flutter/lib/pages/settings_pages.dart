import '../widgets.dart';

// The Throne settings pages. The controls they build with live in
// components/settings_controls.dart.

// --------------------------------------------------------------------------------------------- inbound

/// The configuration surfaces behind one row on the settings list: set once,
/// rarely revisited, and noisy enough beside the common entries that they made
/// the list harder to scan.
class AdvancedSettingsPage extends StatelessWidget {
  const AdvancedSettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return BoxPage(title: 'Advanced settings', children: [
      generateSection(items: [
        ListItem.open(leading: const GlyphIcon(AppGlyphs.devices), title: Text(context.tr('Inbound')), widget: const InboundPage()),
        ListItem.open(leading: const GlyphIcon(AppGlyphs.sliders), title: Text(context.tr('Node presets')), widget: const PresetsPage()),
        ListItem.open(leading: const GlyphIcon(AppGlyphs.profiles), title: Text(context.tr('Subscriptions')), widget: const SubscriptionPage()),
      ], footer: context.tr('Inbound ports, the node templates new nodes are built from, and the subscription profiles.')),
    ]);
  }
}

class InboundPage extends StatelessWidget {
  const InboundPage({super.key});
  @override Widget build(BuildContext context) {
    final vpnMode = context.box.settings['serviceMode'] != 'proxy';
    return BoxPage(title: 'Inbound', actions: [
      restoreDefaultsAction(context, const [
        'inboundSocksPort', 'randomInboundPort', 'allowLan', 'coreDnsInPort', 'disableMixedInbound',
        'inboundAuth', 'inboundUser', 'inboundPass', 'appendHttpProxy', 'httpProxyBypass', 'customInbound',
      ]),
    ], children: [
      generateSection(items: [
        SettingNumber('Mixed port', 'inboundSocksPort', min: 1, max: 65535, autoRestart: true),
        SettingToggle('Random inbound port', 'randomInboundPort'),
        SettingToggle('Allow LAN access', 'allowLan', autoRestart: true),
        SettingNumber('DNS inbound port', 'coreDnsInPort', min: 1, max: 65535, autoRestart: true),
        SettingToggle('Disable the mixed inbound', 'disableMixedInbound', autoRestart: true),
      ], footer: context.tr('These four listeners must use different ports.')),
      generateSection(title: context.tr('Inbound authentication'), items: [
        SettingToggle('Enable authentication', 'inboundAuth', autoRestart: true),
        SettingText('Username', 'inboundUser'),
        SettingText('Password', 'inboundPass'),
      ], footer: vpnMode ? null : context.tr('Proxy-only service mode always keeps the mixed inbound.')),
      if (context.box.capabilities.of('systemProxy')) generateSection(title: context.tr('System proxy'), items: [
        SettingToggle('Append the HTTP proxy', 'appendHttpProxy', autoRestart: true),
        SettingLines('Proxy bypass', 'httpProxyBypass',
          hint: 'One host or CIDR per line. Empty means the proxy is applied to every connection.'),
      ]),
      generateSection(title: context.tr('Custom inbound'), items: [
        SettingJson('Inbound JSON', 'customInbound',
          hint: 'A JSON object with an "inbounds" array, merged into the generated configuration'),
      ], footer: context.tr('The listeners above are generated; these inbounds are added as they are written.')),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------- tun

class TunPage extends StatelessWidget {
  const TunPage({super.key});
  @override Widget build(BuildContext context) => BoxPage(title: 'TUN', actions: [
    restoreDefaultsAction(context, const [
      'vpnMtu', 'vpnIpv6', 'vpnTunIpv4Cidr', 'vpnTunIpv6Cidr', 'allowBypass', 'vpnPrivateRanges', 'enableTunRouting', 'vpnAllowBypass',
    ]),
  ], children: [
    generateSection(items: [
      SettingNumber('MTU', 'vpnMtu', min: 1000, max: 10000, autoRestart: true),
      SettingToggle('TUN IPv6', 'vpnIpv6', autoRestart: true),
      SettingText('TUN IPv4 address', 'vpnTunIpv4Cidr'),
      SettingText('TUN IPv6 address', 'vpnTunIpv6Cidr'),
    ]),
    generateSection(title: context.tr('Routing'), items: [
      SettingToggle('Bypass private ranges', 'allowBypass', autoRestart: true),
      if (context.box.settings['allowBypass'] == true)
        SettingLines('Private ranges', 'vpnPrivateRanges',
          hint: 'One CIDR per line. These are reached directly instead of through the tunnel.'),
      SettingToggle('Route through TUN', 'enableTunRouting'),
      SettingToggle('Allow VPN bypass', 'vpnAllowBypass', autoRestart: true),
    ]),
  ]);
}

// ------------------------------------------------------------------------------------------------- dns

const dnsFinalOuts = ['remote', 'direct'];

class DnsPage extends StatelessWidget {
  const DnsPage({super.key});
  @override Widget build(BuildContext context) {
    // The DNS object replaces every structured setting on this page while it is on, the way the
    // native DNS screen disables its own categories; the toggle itself stays reachable either way.
    final useObject = context.box.settings['useDnsObject'] == true;
    return BoxPage(title: 'DNS', actions: [
      restoreDefaultsAction(context, const [
        'remoteDns', 'remoteDnsDisableIpv6', 'directDns', 'directDnsDisableIpv6', 'dnsFinalOut',
        'enableDnsRouting', 'fakeDns', 'fakeipDisableIpv6', 'dnsUseHosts', 'dnsPredefinedEnable',
        'dnsPredefinedRules', 'coreBoxUnderlyingDns', 'dnsReverseMapping', 'dnsDisableCache',
        'dnsDisableExpire', 'dnsCacheCapacity', 'dnsPersistCache', 'dnsOptimistic', 'dnsOptimisticTimeout',
        'dnsQueryTimeout', 'useDnsObject', 'dnsObject',
      ]),
    ], children: [
      generateSection(items: [
        SettingToggle('Use the DNS object', 'useDnsObject', autoRestart: true),
      ], footer: useObject ? context.tr('The structured settings are ignored while the DNS object is in use.') : null),
      if (useObject)
        SettingJson('DNS object', 'dnsObject',
          hint: 'The sing-box DNS object as JSON; it replaces every structured setting on this page')
      else ...[
        generateSection(title: context.tr('Remote DNS'), items: [
          SettingDnsServer('Remote DNS', 'remoteDns', hint: 'https://1.1.1.1/dns-query', kind: 'remote'),
          SettingToggle('Disable IPv6 answers', 'remoteDnsDisableIpv6'),
        ]),
        generateSection(title: context.tr('Direct DNS'), items: [
          SettingDnsServer('Direct DNS', 'directDns', kind: 'direct'),
          SettingToggle('Disable IPv6 answers', 'directDnsDisableIpv6'),
        ]),
        generateSection(items: [
          SettingChoice<String>('Default DNS server', 'dnsFinalOut', options: dnsFinalOuts, text: (value) => value == 'remote' ? 'Remote DNS' : 'Direct DNS'),
          SettingToggle('DNS routing', 'enableDnsRouting'),
          SettingToggle('FakeDNS', 'fakeDns', autoRestart: true),
          SettingToggle('Disable IPv6 for FakeIP', 'fakeipDisableIpv6'),
          SettingToggle('Use system hosts', 'dnsUseHosts'),
          SettingToggle('Predefined hosts', 'dnsPredefinedEnable'),
          if (context.box.settings['dnsPredefinedEnable'] == true)
            SettingLines('Predefined hosts entries', 'dnsPredefinedRules',
              hint: 'One entry per line, in hosts format: "address hostname".'),
          SettingText('Underlying DNS', 'coreBoxUnderlyingDns', hint: 'empty means the system resolver'),
          SettingToggle('Reverse mapping', 'dnsReverseMapping'),
        ]),
        generateSection(title: context.tr('Cache'), items: [
          SettingToggle('Disable DNS cache', 'dnsDisableCache'),
          SettingToggle('Disable cache expiration', 'dnsDisableExpire'),
          SettingNumber('Cache capacity', 'dnsCacheCapacity', min: 0),
          SettingToggle('Persist the cache', 'dnsPersistCache'),
          SettingToggle('Optimistic cache', 'dnsOptimistic'),
          if (context.box.settings['dnsOptimistic'] == true)
            SettingText('Optimistic cache timeout', 'dnsOptimisticTimeout', hint: 'e.g. 3m'),
          SettingText('Query timeout', 'dnsQueryTimeout', hint: 'e.g. 5s, empty to use the core default'),
        ]),
      ],
      // The DNS rules of a fragment land in the DNS object's `rules` — the one place this build
      // keeps them — so the sheet lives here next to that object, not on a route profile.
      generateSection(title: context.tr('Rules'), items: [
        ListItem(
          leading: const GlyphIcon(AppGlyphs.code),
          title: Text(context.tr('Import DNS rules')),
          subtitle: Text(context.tr('Paste a sing-box fragment with dns.rules; it is checked against the schema first.')),
          onTap: () async {
            final box = context.box;
            final request = await showDialog<RuleImportRequest>(context: context,
              builder: (_) => const RuleImportPage());
            if (request == null || !context.mounted) return;
            try {
              await applyRuleImport(box, request);
            } catch (error) {
              box.report(error);
            }
          },
        ),
      ], footer: useObject
          ? context.tr('Imported rules are appended to the DNS object above.')
          : context.tr('Imported rules are kept in the DNS object, which is switched off here; turn it on for them to apply.')),
    ]);
  }
}

// --------------------------------------------------------------------------------------------- routing

const routingDomainStrategies = ['', 'ipv4_only', 'ipv6_only', 'prefer_ipv4', 'prefer_ipv6'];
const ruleSetMirrors = [0, 1, 2, 3, 4, 5];

class RoutingPage extends StatefulWidget {
  const RoutingPage({super.key});
  @override State<RoutingPage> createState() => _RoutingPageState();
}

/// The Routing page is the rule list itself — no profile picker, no title card.
///
/// A route profile only ever existed to hold a rule list for the configurations
/// that had no override, so the pool that applies to *every* configuration is
/// the page: one list, and one entry to the rules a configuration keeps for
/// itself. The section title went too (the page is already called Routing), and
/// so did WARP's entry, which is an outbound rather than a rule. The switches
/// that decide how rules resolve and mirror sit in the ⋮ menu, and the profile's
/// own unmatched-traffic action still comes from that profile's stored
/// `default_outbound_id`, which the builder reads.
class _RoutingPageState extends State<RoutingPage> {
  final _controller = GlobalRulesController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => Scaffold(
        title: context.tr('Routing'),
        // The search field is the filter the pool body applies; the body owns
        // the query, the bar owns the box.
        searchState: AppBarSearchState(onSearch: _controller.search),
        iconActions: [
          if (_controller.selectionActive) ...[
            IconButtonData(
              glyph: AppGlyphs.selectAll,
              tooltip: context.tr('Select all'),
              onPressed: _controller.selectAllVisible,
            ),
            IconButtonData(
              glyph: AppGlyphs.delete,
              tooltip: context.tr('Delete selected'),
              onPressed: _controller.deleteSelected,
            ),
            IconButtonData(
              glyph: AppGlyphs.close,
              tooltip: context.tr('Cancel'),
              onPressed: _controller.cancelSelection,
            ),
          ] else
            // The way into selection mode. It had no entry before, so the
            // "Delete selected" action above could never appear.
            IconButtonData(
              glyph: AppGlyphs.checkCircle,
              tooltip: context.tr('Select'),
              onPressed: _controller.loading ? null : _controller.startSelection,
            ),
        ],
        // The engine switches, not rule content: they decide how the rules
        // resolve and where the rule-set mirror comes from. They stay reachable
        // here because removing them would drop features rather than align an
        // interaction.
        menuItems: [
          PopupMenuItem(
            glyph: AppGlyphs.rules,
            label: context.tr('Route settings'),
            onPressed: () => openPage(context, const _RouteSettingsPage()),
          ),
          PopupMenuItem(
            glyph: AppGlyphs.sync,
            label: context.tr('Automatic updates'),
            onPressed: () => openPage(context, const _RouteUpdatePage()),
          ),
        ],
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            context.sectionsTopPadding,
            16,
            24 + context.bottomInset,
          ),
          children: [
            // The title card sits above the list, as FlClash's RuleTitle does,
            // and carries this page's primary actions: the bar's icons moved
            // here so "add" reads as part of the rule section rather than as a
            // page-level action.
            generateSection(items: [
              ListItem(
                leading: const GlyphIcon(AppGlyphs.rules),
                title: Text(context.tr('Applied in front of every profile')),
                subtitle: Text(context.tr(
                    'Drag to reorder; the first match wins.')),
                trailing: _controller.loading
                    ? null
                    : IconButton(
                        icon: const GlyphIcon(AppGlyphs.add),
                        tooltip: context.tr('Add rule'),
                        onPressed: _controller.add,
                      ),
              ),
            ]),
            const SizedBox(height: 8),
            GlobalRulesBody(controller: _controller),
          ],
        ),
      ),
    );
  }
}

/// The two domain strategies, the rule-set mirror and ad blocking: the
/// technical switches that used to sit under the pool.
class _RouteSettingsPage extends StatelessWidget {
  const _RouteSettingsPage();
  @override
  Widget build(BuildContext context) => BoxPage(
    title: 'Route settings',
    actions: [
      restoreDefaultsAction(context, const [
        'outboundDomainStrategy', 'domainStrategy', 'rulesetMirror', 'adblockEnable',
      ]),
    ],
    children: [
      generateSection(items: [
        SettingChoice<String>('Outbound domain strategy', 'outboundDomainStrategy',
          options: routingDomainStrategies, text: _strategyName),
        SettingChoice<String>('Domain strategy', 'domainStrategy',
          options: routingDomainStrategies, text: _strategyName),
        SettingChoice<int>('Rule set mirror', 'rulesetMirror', options: ruleSetMirrors, text: _mirrorName),
        SettingToggle('Ad blocking', 'adblockEnable', autoRestart: true),
      ]),
    ],
  );
}

/// The rule-set update pair, split out of the page it used to crowd.
class _RouteUpdatePage extends StatelessWidget {
  const _RouteUpdatePage();
  @override
  Widget build(BuildContext context) => BoxPage(
    title: 'Automatic updates',
    actions: [
      restoreDefaultsAction(context, const [
        'routeAutoUpdateEnabled', 'routeAutoUpdateMinutes',
      ]),
    ],
    children: [
      generateSection(items: [
        SettingToggle('Update rule sets', 'routeAutoUpdateEnabled'),
        if (context.box.settings['routeAutoUpdateEnabled'] == true)
          SettingNumber('Update interval', 'routeAutoUpdateMinutes', min: 30, unit: 'min'),
      ]),
    ],
  );
}

String _strategyName(String value) => switch (value) {
  '' => 'Automatic', 'ipv4_only' => 'IPv4 only', 'ipv6_only' => 'IPv6 only',
  'prefer_ipv4' => 'Prefer IPv4', _ => 'Prefer IPv6',
};

String _mirrorName(int value) => switch (value) {
  1 => 'jsDelivr · Cloudflare', 2 => 'jsDelivr', 3 => 'GitHub',
  4 => 'Cloudflare Pages', 5 => 'Throne mirror', _ => 'GitHub raw',
};

// ------------------------------------------------------------------------------------------------- warp

const warpModes = ['wireguard', 'masque', 'amnezia'];

/// Cloudflare WARP, which Throne treats as an outbound of its own rather than a profile.
///
/// WireGuard and MASQUE keep separate key material, so only the section of the chosen mode is shown;
/// the switch and the registration hosts apply to all three.
class WarpPage extends StatelessWidget {
  const WarpPage({super.key});
  @override Widget build(BuildContext context) {
    final mode = context.box.settings['warpMode']?.toString() ?? 'wireguard';
    return BoxPage(title: 'WARP', actions: [
      restoreDefaultsAction(context, const [
        'enableWarp', 'warpMode', 'warpEndpoint', 'warpPrivateKey', 'warpPublicKey', 'warpIfcAddrs',
        'warpReserved', 'warpMasqueEndpoint', 'warpMasquePrivateKey', 'warpMasquePeerPublicKey',
        'warpMasqueSni', 'warpMasqueHttpMode', 'warpApiHosts', 'warpTosAccepted',
      ]),
    ], children: [
      generateSection(items: [
        SettingToggle('Enable WARP', 'enableWarp', autoRestart: true),
        SettingChoice<String>('WARP mode', 'warpMode', options: warpModes, text: _warpModeName, autoRestart: true),
      ], footer: context.tr('WARP replaces the outbound of the running profile with Cloudflare WARP.')),
      if (mode != 'masque') generateSection(title: context.tr('WireGuard'), items: [
        SettingText('Endpoint', 'warpEndpoint', hint: 'host:port'),
        SettingText('Private key', 'warpPrivateKey'),
        SettingText('Public key', 'warpPublicKey'),
        SettingLines('Interface addresses', 'warpIfcAddrs', hint: 'One CIDR per line, for example 172.16.0.2/32'),
        SettingLines('Reserved bytes', 'warpReserved', hint: 'Three comma-separated integers, usually empty'),
      ]),
      if (mode == 'masque') generateSection(title: context.tr('MASQUE'), items: [
        SettingText('Endpoint', 'warpMasqueEndpoint'),
        SettingText('Private key', 'warpMasquePrivateKey'),
        SettingText('Peer public key', 'warpMasquePeerPublicKey'),
        SettingText('SNI', 'warpMasqueSni'),
        SettingChoice<int>('HTTP mode', 'warpMasqueHttpMode', options: const [0, 1, 2], text: _masqueHttpModeName),
      ]),
      generateSection(title: context.tr('Registration'), items: [
        // Asked once at registration time upstream; accepting it here spares the prompt later.
        SettingToggle('Accept the Cloudflare license', 'warpTosAccepted'),
        SettingLines('API hosts', 'warpApiHosts', hint: 'Empty uses api.cloudflareclient.com'),
        const _WarpRegisterRow(),
      ], footer: context.tr('A generated identity fills the fields of the mode above. Enable WARP to route traffic through it.')),
    ]);
  }
}

String _warpModeName(String value) => switch (value) {
  'masque' => 'MASQUE', 'amnezia' => 'AmneziaWG', _ => 'WireGuard',
};

String _masqueHttpModeName(int value) => switch (value) {
  1 => 'HTTP/3 only', 2 => 'HTTP/2 only', _ => 'HTTP/3 with fallback',
};

/// The native "Generate" row (WarpSettingsScreen's KEY_GENERATE): registers an identity for the
/// mode's tunnel type, saves the keys that mode uses and reloads the service when WARP is on.
///
/// The Cloudflare terms are asked once, as upstream's confirmTerms does — a second visit with the
/// license already accepted goes straight to the registration.
class _WarpRegisterRow extends StatefulWidget {
  const _WarpRegisterRow();
  @override
  State<_WarpRegisterRow> createState() => _WarpRegisterRowState();
}

class _WarpRegisterRowState extends State<_WarpRegisterRow> {
  bool _busy = false;

  Future<void> _register() async {
    final box = context.box;
    if (box.settings['warpTosAccepted'] != true) {
      final accepted = await confirm(
        context,
        'Cloudflare WARP',
        message: 'Generating a WARP identity registers a new device with Cloudflare.\n\n'
          'Do you accept the Cloudflare WARP terms of service?\n\n'
          'https://www.cloudflare.com/application/terms/',
        action: 'Accept',
      );
      if (!accepted || !mounted) return;
      await box.setSetting('warpTosAccepted', true, restart: false);
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      // MASQUE registers a MASQUE identity; the other two modes run WireGuard key material.
      final masque = box.settings['warpMode']?.toString() == 'masque';
      final answer = json(await box.warpRegister(masque ? 'masque' : 'wireguard'));
      if (!mounted) return;
      if (answer['reload'] == true) box.serviceReload();
      final packetsError = answer['packetsError']?.toString() ?? '';
      final message = packetsError.isEmpty
        ? 'Identity generated'
        : 'Identity generated, the AmneziaWG packets failed: {error}'.replaceAll('{error}', packetsError);
      showAppBanner(context, context.tr(message));
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListItem(
    title: Text(context.tr('Generate identity')),
    subtitle: Text(context.tr(_busy ? 'Generating…' : 'Registers a new identity and fills the fields above')),
    onTap: _busy ? null : _register,
  );
}

// ------------------------------------------------------------------------------------------------ core

const logLevels = ['trace', 'debug', 'info', 'warn', 'error', 'fatal', 'panic'];
const xrayLogLevels = ['debug', 'info', 'warning', 'error', 'none'];
const ntpOutbounds = ['direct', 'proxy'];

class CorePage extends StatelessWidget {
  const CorePage({super.key});
  @override Widget build(BuildContext context) {
    final clashApi = context.box.settings['clashApiEnabled'] == true;
    final boxApi = context.box.settings['boxApiEnabled'] == true;
    return BoxPage(title: 'Core', actions: [
      restoreDefaultsAction(context, const [
        'logLevel', 'xrayLogLevel', 'logBufSize', 'enableStats', 'disableTrafficStats', 'skipCert',
        'useMozillaCerts', 'xrayUseSystemCa', 'xrayVlessPreference', 'clashApiEnabled', 'clashApiPort',
        'clashApiListenAddr', 'clashApiSecret', 'boxApiEnabled', 'boxApiPort', 'boxApiSecret',
        'enableNtp', 'ntpServerAddress', 'ntpServerPort', 'ntpInterval', 'ntpOutbound',
      ]),
    ], children: [
      // The categories and their order are Throne's settings_core.
      generateSection(title: context.tr('Logging'), items: [
        ListItem(title: Text(context.tr('Core version')), subtitle: Text(context.box.coreVersion)),
        SettingChoice<String>('Log level', 'logLevel', options: logLevels, text: (value) => value.toUpperCase(), autoRestart: true),
        SettingChoice<String>('Xray log level', 'xrayLogLevel', options: xrayLogLevels, text: (value) => value.toUpperCase(), autoRestart: true),
        SettingNumber('Log buffer', 'logBufSize', min: 0, unit: 'KiB'),
      ]),
      generateSection(title: context.tr('Statistics'), items: [
        SettingToggle('Traffic statistics', 'enableStats', autoRestart: true),
        SettingToggle('Disable per-profile statistics', 'disableTrafficStats', autoRestart: true),
      ]),
      generateSection(title: context.tr('Clash API'), items: [
        SettingToggle('Enable Clash API', 'clashApiEnabled', autoRestart: true),
        if (clashApi) ...[
          SettingNumber('Port', 'clashApiPort', min: 1, max: 65535, autoRestart: true),
          SettingText('Listen address', 'clashApiListenAddr'),
          SettingText('Secret', 'clashApiSecret'),
        ],
      ]),
      generateSection(title: context.tr('API dashboard'), items: [
        SettingToggle('Enable core API', 'boxApiEnabled', autoRestart: true),
        if (boxApi) ...[
          SettingNumber('Port', 'boxApiPort', min: 1, max: 65535, autoRestart: true),
          SettingText('Secret', 'boxApiSecret'),
        ],
      ]),
      // Which transports' VLESS nodes are built for the Xray core instead of sing-box.
      generateSection(title: context.tr('Xray'), items: [
        SettingChoice<int>('Xray VLESS preference', 'xrayVlessPreference',
          options: xrayVlessPreferences, text: xrayVlessPreferenceName),
      ]),
      generateSection(title: context.tr('Security'), items: [
        SettingToggle('Skip certificate verification', 'skipCert'),
        SettingToggle('Use the Mozilla root store', 'useMozillaCerts'),
        SettingToggle('Xray uses the system CA', 'xrayUseSystemCa'),
      ]),
      generateSection(title: context.tr('NTP'), items: [
        SettingToggle('Enable NTP', 'enableNtp', autoRestart: true),
        SettingText('NTP server', 'ntpServerAddress'),
        SettingNumber('NTP port', 'ntpServerPort', min: 0, max: 65535),
        SettingText('NTP interval', 'ntpInterval', hint: 'e.g. 30m, empty to use the core default'),
        SettingChoice<String>('NTP outbound', 'ntpOutbound', options: ntpOutbounds, text: (value) => value),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------------------------------------- testing

const speedTestModes = [0, 1, 2, 3, 4];

/// VLESS nodes are built for the Xray core only for the transports the preference names;
/// the rest stay with sing-box. The order matches `xray_vless_preference_entries`.
const xrayVlessPreferences = [0, 1, 2];

String xrayVlessPreferenceName(int value) => switch (value) {
  0 => 'XHTTP only', 1 => 'XHTTP and Reality', _ => 'All VLESS',
};
const exitLookupProviders = ['auto', 'ip-api', 'ipwho', 'ipinfo', 'ipapi-co', 'ip2location', 'freeipapi', 'cloudflare'];

/// Three choices cannot be honoured by the probe set as it stands: ip-api's free
/// endpoint is plain HTTP, ip2location needs an API key, and cloudflare answers
/// plain text rather than JSON. Name that in the picker instead of letting a
/// change look like it did nothing (they fall back to the default order).
String exitLookupProviderName(String value) => switch (value) {
  'ip-api' => 'Lookup provider cleartext',
  'ip2location' => 'Lookup provider needs key',
  'cloudflare' => 'Lookup provider fallback',
  _ => value,
};

class TestingPage extends StatelessWidget {
  const TestingPage({super.key});
  @override Widget build(BuildContext context) => BoxPage(title: 'Testing', actions: [
    restoreDefaultsAction(context, const [
      'testUrl', 'urlTestTimeoutMs', 'testConcurrent', 'directTestUrl', 'speedTestMode',
      'speedTestTimeoutMs', 'simpleDlUrl', 'exitCountryLookup', 'exitLookupProvider',
    ]),
  ], children: [
    generateSection(items: [
      SettingText('Test URL', 'testUrl'),
      SettingNumber('Test timeout', 'urlTestTimeoutMs', min: 0, unit: 'ms'),
      SettingNumber('Concurrent tests', 'testConcurrent', min: 1, max: 499),
      SettingText('Direct test URL', 'directTestUrl'),
    ]),
    generateSection(title: context.tr('Speed test'), items: [
      SettingChoice<int>('Speed test mode', 'speedTestMode', options: speedTestModes, text: speedTestModeName),
      SettingNumber('Speed test timeout', 'speedTestTimeoutMs', min: 0, unit: 'ms'),
      if (context.box.settings['speedTestMode'] == 3)
        SettingText('Simple download URL', 'simpleDlUrl', hint: 'A file of known size used to measure throughput'),
    ]),
    generateSection(title: context.tr('Exit detection'), items: [
      SettingToggle('Look up exit country', 'exitCountryLookup'),
      SettingChoice<String>('Lookup provider', 'exitLookupProvider', options: exitLookupProviders, text: exitLookupProviderName),
    ]),
  ]);
}

String speedTestModeName(int value) => switch (value) {
  1 => 'Download', 2 => 'Upload', 3 => 'Simple download', 4 => 'Country', _ => 'Download and upload',
};

// ------------------------------------------------------------------------------------------ node presets

const muxProtocols = ['h2mux', 'smux', 'yamux'];
const muxModes = ['max_streams', 'max_connections'];
const xrayXudpModes = ['reject', 'allow', 'skip'];
const fragmentImplementations = ['built-in', 'custom'];
const utlsFingerprints = [
  '', 'chrome', 'firefox', 'edge', 'safari', '360', 'qq', 'ios', 'android',
  'random', 'randomized', 'unsafe',
];

/// The defaults the importer stamps on the nodes it builds — Mux, Xray multiplex, fragment, TLS
/// tricks, HTTP/2 tuning and the QUIC dialer. A running configuration is never rebuilt from these;
/// they apply to the next import or creation, exactly as the native preset screen does.
class PresetsPage extends StatelessWidget {
  const PresetsPage({super.key});
  @override Widget build(BuildContext context) {
    final settings = context.box.settings;
    final brutal = settings['muxBrutal'] == true;
    final muxMode = settings['muxMode']?.toString() ?? 'max_streams';
    final brutalReady = (settings['muxBrutalUpMbps'] as num? ?? 0) > 0 &&
        (settings['muxBrutalDownMbps'] as num? ?? 0) > 0;
    final fragmentCustom = settings['fragmentImplementation'] == 'custom';
    final fingerprint = settings['utlsFingerprint']?.toString() ?? '';
    final fingerprints = utlsFingerprints.contains(fingerprint)
        ? utlsFingerprints
        : [fingerprint, ...utlsFingerprints];
    return BoxPage(title: 'Node presets', actions: [
      restoreDefaultsAction(context, const [
        'muxProtocol', 'muxMode', 'muxConcurrency', 'muxMaxConnections', 'muxMinStreams', 'muxPadding',
        'muxBrutal', 'muxBrutalUpMbps', 'muxBrutalDownMbps', 'muxDefaultOn', 'xrayMuxConcurrency',
        'xrayMuxMaxConnections', 'xrayMuxXudpConcurrency', 'xrayMuxXudpProxyUdp443', 'xrayMuxDefaultOn',
        'fragmentDefaultOn', 'fragmentImplementation', 'fragmentSize', 'fragmentSleep', 'tlsTricksDefaultOn',
        'utlsFingerprint', 'h2IdleTimeout', 'h2KeepAlivePeriod',
        'h2StreamReceiveWindow', 'h2ConnectionReceiveWindow', 'h2MaxConcurrentStreams',
        'quicInitialPacketSize', 'quicDisablePathMtuDiscovery',
      ]),
    ], children: [
      generateSection(title: context.tr('Mux'), items: [
        SettingChoice<String>('Mux protocol', 'muxProtocol', options: muxProtocols, text: (value) => value),
        SettingChoice<String>('Mux mode', 'muxMode', options: muxModes, text: _muxModeName, enabled: !brutal),
        if (muxMode == 'max_connections')
          SettingNumber('Mux max connections', 'muxMaxConnections', min: 1, enabled: !brutal)
        else
          SettingNumber('Mux concurrency', 'muxConcurrency', min: 1, enabled: !brutal),
        if (muxMode == 'max_connections')
          SettingNumber('Mux min streams', 'muxMinStreams', min: 0, enabled: !brutal),
        SettingToggle('Mux padding', 'muxPadding'),
        SettingToggle('Brutal congestion', 'muxBrutal', enabled: brutal || brutalReady),
        SettingNumber('Brutal upload', 'muxBrutalUpMbps', min: 0, unit: 'Mbps'),
        SettingNumber('Brutal download', 'muxBrutalDownMbps', min: 0, unit: 'Mbps'),
        SettingToggle('Enable Mux by default', 'muxDefaultOn'),
      ], footer: context.tr('Applied when a node is imported, not to nodes already saved.')),
      generateSection(title: context.tr('Xray multiplex'), items: [
        SettingNumber('Concurrency', 'xrayMuxConcurrency', min: -1, max: 32767),
        SettingNumber('Max connections', 'xrayMuxMaxConnections', min: 0, max: 32767),
        SettingNumber('XUDP concurrency', 'xrayMuxXudpConcurrency', min: -1, max: 32767),
        SettingChoice<String>('XUDP proxy UDP/443', 'xrayMuxXudpProxyUdp443', options: xrayXudpModes, text: (value) => value),
        SettingToggle('Enable Xray Mux by default', 'xrayMuxDefaultOn'),
      ]),
      generateSection(title: context.tr('Fragment'), items: [
        SettingChoice<String>('Fragment implementation', 'fragmentImplementation',
          options: fragmentImplementations, text: _fragmentImplementationName),
        SettingText('Fragment size', 'fragmentSize', enabled: fragmentCustom,
          hint: 'custom only: e.g. 10-100, empty uses the built-in range'),
        SettingText('Fragment sleep', 'fragmentSleep', enabled: fragmentCustom,
          hint: 'custom only: e.g. 2-5, empty uses the built-in range'),
        SettingToggle('Fragment by default', 'fragmentDefaultOn'),
      ]),
      generateSection(title: context.tr('TLS tricks'), items: [
        SettingToggle('TLS tricks by default', 'tlsTricksDefaultOn'),
      ]),
      generateSection(title: context.tr('uTLS'), items: [
        SettingChoice<String>('uTLS fingerprint', 'utlsFingerprint', options: fingerprints, text: _utlsFingerprintName),
      ]),
      generateSection(title: context.tr('HTTP/2 and QUIC'), items: [
        SettingText('Idle timeout', 'h2IdleTimeout', hint: 'e.g. 5m, empty to use the core default'),
        SettingText('Keep-alive period', 'h2KeepAlivePeriod', hint: 'e.g. 30s, empty to use the core default'),
        SettingText('Stream receive window', 'h2StreamReceiveWindow'),
        SettingText('Connection receive window', 'h2ConnectionReceiveWindow'),
        SettingNumber('Max concurrent streams', 'h2MaxConcurrentStreams', min: 0),
        SettingNumber('Initial packet size', 'quicInitialPacketSize', min: 0, unit: 'B'),
        SettingToggle('Disable path MTU discovery', 'quicDisablePathMtuDiscovery'),
      ], footer: context.tr('Used by Hysteria, Hysteria2, TUIC and MASQUE profiles that leave a field empty. Empty keeps the core default.')),
    ]);
  }
}

String _muxModeName(String value) => value == 'max_connections' ? 'Max connections' : 'Max streams';

String _fragmentImplementationName(String value) =>
    value == 'custom' ? 'Custom (dialer)' : 'Built-in (sing-box)';

String _utlsFingerprintName(String value) => value.isEmpty ? 'Default' : value;

// ---------------------------------------------------------------------------------------- subscriptions

const subscriptionTlsVersions = [0, 1, 2];
const subscriptionHttpVersions = [0, 1];

class SubscriptionPage extends StatelessWidget {
  const SubscriptionPage({super.key});
  @override Widget build(BuildContext context) {
    final autoUpdate = context.box.settings['subAutoUpdateEnabled'] == true;
    return BoxPage(title: 'Subscriptions', actions: [
      restoreDefaultsAction(context, const [
        'userAgent', 'netUseProxy', 'netInsecure', 'subTlsVersion', 'subHttpVersion', 'subSendHwid',
        'subCustomHwidParams', 'subAutoUpdateEnabled', 'subAutoUpdateMinutes', 'subRespectServerInterval',
        'subClear', 'subShowChangePopup', 'allowStoppingActiveProfile',
      ]),
    ], children: [
      generateSection(title: context.tr('Request'), items: [
        SettingText('User agent', 'userAgent', hint: 'empty means the built-in user agent'),
        SettingToggle('Fetch through the proxy', 'netUseProxy'),
        SettingToggle('Allow insecure TLS', 'netInsecure'),
        SettingChoice<int>('TLS version', 'subTlsVersion', options: subscriptionTlsVersions, text: _tlsVersionName),
        SettingChoice<int>('HTTP version', 'subHttpVersion', options: subscriptionHttpVersions, text: _httpVersionName),
        SettingToggle('Send device identifier', 'subSendHwid'),
        if (context.box.settings['subSendHwid'] == true)
          SettingText('Custom HWID parameters', 'subCustomHwidParams',
            hint: 'key=value pairs separated by commas, sent alongside the identifier'),
      ]),
      generateSection(title: context.tr('Automatic updates'), items: [
        SettingToggle('Update subscriptions', 'subAutoUpdateEnabled'),
        if (autoUpdate) SettingNumber('Update interval', 'subAutoUpdateMinutes', min: 30, unit: 'min'),
        SettingToggle('Respect the server interval', 'subRespectServerInterval'),
      ]),
      generateSection(title: context.tr('Updating'), items: [
        SettingToggle('Clear on failure', 'subClear'),
        SettingToggle('Show the change report', 'subShowChangePopup'),
        SettingToggle('Allow stopping the running profile', 'allowStoppingActiveProfile'),
      ]),
    ]);
  }
}

String _tlsVersionName(int value) => switch (value) { 1 => 'TLS 1.2', 2 => 'TLS 1.3', _ => 'Automatic' };
String _httpVersionName(int value) => switch (value) { 1 => 'HTTP/1.1', _ => 'Automatic' };

// -------------------------------------------------------------------------------------------------- misc

class UpdatePage extends StatelessWidget {
  const UpdatePage({super.key});
  @override Widget build(BuildContext context) => BoxPage(title: 'Updates', actions: [
    restoreDefaultsAction(context, const ['allowBetaUpdate', 'updateCheckAuto']),
  ], children: [
    generateSection(items: [
      SettingToggle('Allow beta versions', 'allowBetaUpdate'),
      SettingToggle('Check for updates automatically', 'updateCheckAuto'),
    ]),
  ]);
}
