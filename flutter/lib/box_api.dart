part of 'box.dart';

/// Semantic facade (Bettbox `ClashCore`-style): folds the scattered raw bridge
/// invocations — a bare name string plus an argument map — into typed, discoverable methods,
/// so the name is checked at compile time and the parameter shape lives in one place.
/// Grouped by domain as `extension`s on [BoxController].
extension ProfilesApi on BoxController {
  Future<dynamic> profileDecodeIntent(String uri) => call('profiles.decodeIntent', {'uri': uri});
  Future<dynamic> profileAutoSelectorInfo(dynamic id) => call('profiles.autoSelectorInfo', {'id': id});
  Future<dynamic> profileAutoSelectorStatus() => call('profiles.autoSelectorStatus');
  Future<dynamic> profileAutoSelectorPin(dynamic id, dynamic memberId) => call('profiles.autoSelectorPin', {'id': id, 'memberId': memberId});
  Future<dynamic> profileAutoSelectorRecheck() => call('profiles.autoSelectorRecheck', {});
  Future<dynamic> profileAutoSelectorSave(dynamic id, Json value) => call('profiles.autoSelectorSave', {'id': id, 'value': value});
  Future<dynamic> profileAutoSelectorCreate(dynamic groupId) => call('profiles.autoSelectorCreate', {'groupId': groupId});
  Future<dynamic> profileConfig(dynamic id) => call('profiles.config', {'id': id});
  Future<bool> profileUpdate(dynamic id) => act('profiles.update', {'id': id});
  Future<dynamic> profileNodeLink(String group, String tag, dynamic nodeJson) => call('profiles.nodeLink', {'group': group, 'tag': tag, 'json': nodeJson});
  Future<dynamic> profileNodeDelete(dynamic id) => call('profiles.nodeDelete', {'id': id});
  Future<dynamic> profileNodeConfig(dynamic id) => call('profiles.nodeConfig', {'id': id});
  Future<dynamic> profileNodeUpdate(dynamic id, String name, String content) => call('profiles.nodeUpdate', {'id': id, 'name': name, 'content': content});
  Future<dynamic> profileNodeTuningInfo(dynamic id) => call('profiles.nodeTuningInfo', {'id': id});
  Future<dynamic> profileNodeTuningSave(dynamic id, Json value) => call('profiles.nodeTuningSave', {'id': id, 'value': value});
  Future<dynamic> profileRead(dynamic id) => call('profiles.read', {'id': id});
  Future<bool> profileClearTestResults(dynamic id) => act('profiles.clearTestResults', {'id': id});
  Future<bool> profileClearTraffic(dynamic id) => act('profiles.clearTraffic', {'id': id});
  Future<bool> profileDelete(dynamic id) => act('profiles.delete', {'id': id});
  Future<bool> profileSwitchRelative(int step) => act('profiles.switchRelative', {'step': step});
  Future<bool> profileSelect(dynamic id) => act('profiles.select', {'id': id});
  Future<dynamic> profileImportFile() => call('profiles.importFile');
  Future<dynamic> profileCreateNode(dynamic groupId, dynamic type) => call('profiles.createNode', {'groupId': groupId, 'type': type});
  Future<dynamic> profileSave(Json value) => call('profiles.save', value);
  Future<bool> profileReorder(List<dynamic> ids) => act('profiles.reorder', {'ids': ids});
  Future<bool> profileScanClose(dynamic session) => act('profiles.scan.close', {'session': session});
  Future<dynamic> profileScan(dynamic session, String text) => call('profiles.scan', {'session': session, 'text': text});
  Future<dynamic> profileWrite(dynamic id, String content, dynamic revision) => call('profiles.write', {'id': id, 'content': content, 'revision': revision});
}

extension RoutesApi on BoxController {
  Future<dynamic> routeList() => call('routes.list');
  Future<dynamic> routePresets() => call('routes.presets');
  Future<dynamic> routeAddPreset(dynamic country) => call('routes.addPreset', {'country': country, 'autoUpdate': true});
  Future<dynamic> routeGet(dynamic id) => call('routes.get', {'id': id});
  Future<dynamic> routeRules(dynamic id) => call('routes.rules', {'id': id});
  Future<dynamic> routeBatchAddRules(dynamic id, String text) => call('routes.batchAddRules', {'id': id, 'text': text});
  Future<dynamic> routeResetRules(dynamic id) => call('routes.resetRules', {'id': id});
  Future<dynamic> routeSave(Json value) => call('routes.save', {'value': value});
  Future<dynamic> routeDelete(dynamic id) => call('routes.delete', {'id': id});
  Future<dynamic> routeSetCurrent(dynamic id) => call('routes.setCurrent', {'id': id});
  Future<dynamic> routeSaveRules(dynamic id, dynamic rules) => call('routes.saveRules', {'id': id, 'rules': rules});
  Future<dynamic> routeRuleSets(String query, int limit) => call('routes.ruleSets', {'query': query, 'limit': limit});
}

extension TerminalApi on BoxController {
  Future<dynamic> terminalSettings() => call('terminal.settings');
  Future<dynamic> terminalSet(dynamic key, dynamic value) => call('terminal.set', {'key': key, 'value': value});
  Future<bool> terminalSetChecked(dynamic key, dynamic value) => act('terminal.set', {'key': key, 'value': value});
  Future<dynamic> terminalThemes(bool dark) => call('terminal.themes', {'dark': dark});
  Future<dynamic> terminalFonts() => call('terminal.fonts');
  Future<bool> terminalImportFont() => act('terminal.importFont');
  Future<bool> terminalDeleteFont(dynamic path) => act('terminal.deleteFont', {'path': path});
}

extension ReportsApi on BoxController {
  Future<dynamic> reportList(String kind) => call('reports.list', {'kind': kind});
  Future<bool> reportClear(String kind) => act('reports.clear', {'kind': kind});
  Future<dynamic> reportFiles(Json args) => call('reports.files', args);
  Future<bool> reportDelete(Json args) => act('reports.delete', args);
  Future<bool> reportSave(Json args) => act('reports.save', args);
  Future<bool> reportExport(Json args) => act('reports.export', args);
  Future<dynamic> reportRead(Json args) => call('reports.read', args);
}

extension GroupsApi on BoxController {
  Future<bool> groupTest(dynamic tag) => act('groups.test', {'tag': tag});
  Future<bool> groupSelect(dynamic group, dynamic tag) => act('groups.select', {'group': group, 'tag': tag});
  Future<dynamic> groupTestSessionStart(Json args) => call('groups.testSession.start', args);
  Future<bool> groupTestSessionStartChecked(Json args) => act('groups.testSession.start', args);
  Future<bool> groupTestSessionStop() => act('groups.testSession.stop');
  Future<bool> groupTestSessionSort(dynamic groupId) => act('groups.testSession.sort', {'groupId': groupId});
  Future<dynamic> groupTestSessionRemove(List<dynamic> ids) => call('groups.testSession.remove', {'ids': ids});
  Future<bool> groupTestSessionDismiss() => act('groups.testSession.dismiss');
}

extension GroupSettingsApi on BoxController {
  Future<dynamic> groupSettingsGet(dynamic id) => call('groupSettings.get', {'id': id});
  Future<dynamic> groupSettingsSet(Json value) => call('groupSettings.set', {'value': value});
}

extension SshApi on BoxController {
  Future<dynamic> sshSnapshot() => call('ssh.snapshot');
  Future<dynamic> sshOptions(dynamic endpoint, dynamic peer) => call('ssh.options', {'endpoint': endpoint, 'peer': peer});
  Future<dynamic> sshStart(dynamic endpoint, dynamic peer, {dynamic username, dynamic terminalType, dynamic remember}) => call('ssh.start', {'endpoint': endpoint, 'peer': peer, 'username': username, 'terminalType': terminalType, 'remember': remember});
  Future<bool> sshClose(dynamic id) => act('ssh.close', {'id': id});
  Future<bool> sshDuplicate() => act('ssh.duplicate');
  Future<bool> sshSelect(dynamic id) => act('ssh.select', {'id': id});
}

extension WebdavApi on BoxController {
  Future<dynamic> webdavGet() => call('webdav.get');
  Future<dynamic> webdavCheck() => call('webdav.check');
  Future<dynamic> webdavSet(dynamic value) => call('webdav.set', {'value': value});
  Future<dynamic> webdavUpload() => call('webdav.upload');
}

extension TaildropApi on BoxController {
  Future<bool> taildropSubscribe(dynamic endpoint) => act('taildrop.subscribe', {'endpoint': endpoint});
  Future<bool> taildropUnsubscribe() => act('taildrop.unsubscribe');
  Future<bool> taildropCancelReceive(dynamic endpoint, dynamic name, dynamic sender) => act('taildrop.cancelReceive', {'endpoint': endpoint, 'name': name, 'sender': sender});
  Future<bool> taildropSave(dynamic endpoint, dynamic name) => act('taildrop.save', {'endpoint': endpoint, 'name': name});
  Future<bool> taildropDelete(dynamic endpoint, dynamic name) => act('taildrop.delete', {'endpoint': endpoint, 'name': name});
  Future<dynamic> taildropSend(dynamic args) => call('taildrop.send', args);
}

extension RemoteApi on BoxController {
  Future<dynamic> remoteList() => call('remote.list');
  Future<bool> remoteDisconnect() => act('remote.disconnect');
  Future<bool> remoteConnect(dynamic id) => act('remote.connect', {'id': id});
  Future<bool> remoteDelete(dynamic id) => act('remote.delete', {'id': id});
  Future<bool> remoteSave(Json value) => act('remote.save', value);
}

extension ConnectionsApi on BoxController {
  Future<bool> connectionsSetVisible(bool visible) => act('connections.visible', {'visible': visible});
  Future<bool> connectionsCloseAll() => act('connections.closeAll');
  Future<bool> connectionsClose(dynamic id) => act('connections.close', {'id': id});
}

extension UrlApi on BoxController {
  Future<bool> openUrl(String url) => act('url.open', {'url': url});
}

extension DocumentApi on BoxController {
  Future<dynamic> documentSave(String name, String content, {bool redact = false}) => call('document.save', {'name': name, 'content': content, if (redact) 'redact': true});
}

extension AppsApi on BoxController {
  Future<dynamic> appsList(Json args) => call('apps.list', args);
  Future<bool> appsPermission() => act('apps.permission');
}

extension ShareApi on BoxController {
  Future<dynamic> shareText(dynamic content) => call('share.text', {'content': content});
  Future<bool> shareSend(dynamic token, dynamic endpoint, dynamic peer) => act('share.send', {'token': token, 'endpoint': endpoint, 'peer': peer});
  Future<bool> shareDiscard(dynamic token) => act('share.discard', {'token': token});
}

extension ServiceApi on BoxController {
  Future<bool> serviceReload({bool restart = false}) => act('service.reload', restart ? {'restart': true} : null);
  Future<bool> serviceStart() => act('service.start');
}

extension CaptureApi on BoxController {
  Future<bool> captureExport(Json args) => act('capture.export', args);
  Future<dynamic> captureSettings() => call('capture.settings');
  Future<dynamic> captureDomains(String query) => call('capture.domains', {'query': query});
  Future<dynamic> captureConfigure(dynamic revision, Json config) => call('capture.configure', {'revision': revision, 'config': config});
}

extension TailscaleApi on BoxController {
  Future<bool> tailscaleStopPing() => act('tailscale.stopPing');
  Future<bool> tailscalePing(dynamic args) => act('tailscale.ping', args);
  Future<bool> tailscaleLogout(dynamic endpoint) => act('tailscale.logout', {'endpoint': endpoint});
  Future<bool> tailscaleExit(dynamic endpoint, dynamic peer) => act('tailscale.exit', {'endpoint': endpoint, 'peer': peer});
}

extension UsbApi on BoxController {
  Future<dynamic> usbList() => call('usb.list');
  Future<bool> usbDetach(dynamic id) => act('usb.detach', {'id': id});
  Future<bool> usbAttach(dynamic server, dynamic device) => act('usb.attach', {'server': server, 'device': device});
}

extension DashboardApi on BoxController {
  Future<bool> dashboardReleaseMemory() => act('dashboard.releaseMemory');
  Future<dynamic> dashboardProbeOpen(dynamic id) => call('dashboard.probe.open', {'id': id});
  Future<dynamic> dashboardProbeGet(dynamic id, String url, int timeoutMillis) => call('dashboard.probe.get', {'id': id, 'url': url, 'timeoutMillis': timeoutMillis});
  Future<dynamic> dashboardProbeClose(dynamic id) => call('dashboard.probe.close', {'id': id});
  Future<dynamic> dashboardEgress(dynamic id, {bool force = false}) => call('dashboard.egress', {'id': id, if (force) 'force': true});
}

extension CrashesApi on BoxController {
  Future<dynamic> crashesList() => call('crashes.list', {});
  Future<dynamic> crashesRead(dynamic name) => call('crashes.read', {'name': name});
}

extension BackupApi on BoxController {
  Future<dynamic> backupCreate() => call('backup.create');
  Future<dynamic> backupRestore(dynamic backup, dynamic scope, dynamic strategy) => call('backup.restore', {'backup': backup, 'scope': scope, 'strategy': strategy});
}

extension MiscApi on BoxController {
  Future<dynamic> updatesCheck() => call('updates.check');
  Future<bool> wifiPermissionsEnsure() => act('wifiPermissions.ensure');
  Future<bool> systemProxySet(bool enabled) => act('systemProxy.set', {'enabled': enabled});
  Future<bool> modeSet(dynamic mode) => act('mode.set', {'mode': mode});
  Future<dynamic> filesOpen(String uri) => call('files.open', {'uri': uri});
  Future<dynamic> dnsSuggestions() => call('dns.suggestions');
  Future<bool> batteryOpen() => act('battery.open');
  Future<dynamic> configCheck(String content) => call('config.check', {'content': content});
  Future<dynamic> warpRegister(String tunnelType) => call('warp.register', {'tunnelType': tunnelType});
}
