import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

/// Throne's repository remains authoritative. These calls are part of the
/// native Core endpoint (`throne.profile.*`), not a page-level bridge or a
/// second state owner: FlClash's profile cards map one-to-one onto Throne's
/// groups, and the native side imports node content with Throne's own parser.
extension ThroneProfileCore on CoreController {
  /// The native list, or null when the Core cannot answer right now.
  ///
  /// The Core is not connected for the first seconds of a launch (bootstrap
  /// runs before `CoreLib.start()`), so an unavailable Core is a normal state
  /// there rather than an error: the null answer lets the callers keep what
  /// they have and read again once the Core is up.
  Future<List<Profile>?> tryListThroneProfiles() async {
    final Object? result;
    try {
      result = await invokeMethod(method: CoreMethod.throneProfileList);
    } on CoreMethodException catch (error) {
      if (!error.isCoreUnavailable) rethrow;
      return null;
    } on TimeoutException {
      return null;
    }
    if (result is! List) return const [];
    return [
      for (final item in result.whereType<Map>())
        _profile(Map<String, dynamic>.from(item)),
    ];
  }

  /// [tryListThroneProfiles] with the unavailable-Core answer folded to empty,
  /// for callers that show the rows rather than reconciling them.
  Future<List<Profile>> listThroneProfiles() async {
    return await tryListThroneProfiles() ?? const [];
  }

  /// Saves the group and imports [content] when it is not empty.
  ///
  /// Content must go in only when Throne has no nodes for the group yet: its
  /// import appends every node it reads, so resending a document on a metadata
  /// edit (a rename, a proxy pick) would duplicate the whole group's rows.
  /// Whether a save carries content is therefore the caller's decision, taken
  /// from what it knows about the group rather than from what happens to be on
  /// disk.
  ///
  /// The answer is the group as stored, whose id is Throne's own: that is the
  /// one later calls and the profile list use, so a caller importing a new
  /// profile adopts it rather than keeping its own id.
  Future<Profile?> saveThroneProfile(
    Profile profile, {
    String content = '',
  }) async {
    final result = await invokeMethod(
      method: CoreMethod.throneProfileSave,
      arguments: {
        'id': profile.id,
        'name': profile.realLabel,
        'url': profile.url,
        'autoUpdate': profile.autoUpdate,
        'interval': profile.autoUpdateDuration.inMinutes,
        'content': content,
      },
    );
    return result is Map ? _profile(Map<String, dynamic>.from(result)) : null;
  }

  /// The document [addProfileFormFile] and [Profile.saveFile] write, read whole
  /// so the save that follows import can hand it to Throne.
  Future<String?> readProfileDocument(int id) async {
    try {
      final file = File(await appPath.getProfilePath('$id'));
      if (await file.exists()) return await file.readAsString();
    } catch (_) {
      // A metadata-only save is still useful without the document.
    }
    return null;
  }

  Future<void> deleteThroneProfile(int id) async {
    await invokeMethod(
      method: CoreMethod.throneProfileDelete,
      arguments: {'id': id},
    );
  }

  /// A metadata update of a group Throne already holds: no document is read,
  /// because a subscription group fetches its own content on the refresh this
  /// triggers, and a local one keeps the nodes it imported. The answer is the
  /// group as stored, so the caller reports what Throne now has rather than
  /// waiting for the next poll.
  Future<Profile?> updateThroneProfile(Profile profile) async {
    final result = await invokeMethod(
      method: CoreMethod.throneProfileUpdate,
      arguments: {
        'id': profile.id,
        'name': profile.realLabel,
        'url': profile.url,
      },
    );
    return result is Map ? _profile(Map<String, dynamic>.from(result)) : null;
  }
}

Profile _profile(Map<String, dynamic> item) {
  final info = item['subscriptionInfo'];
  return Profile(
    id: (item['id'] as num).toInt(),
    type: item['subscription'] == true ? ProfileType.url : ProfileType.file,
    label: item['name'] as String? ?? '',
    url: item['url'] as String? ?? '',
    autoUpdate: item['autoUpdate'] as bool? ?? true,
    autoUpdateDuration: Duration(
      minutes: (item['interval'] as num?)?.toInt() ?? 1440,
    ),
    lastUpdateDate: switch (item['lastUpdate']) {
      final num value when value > 0 =>
        DateTime.fromMillisecondsSinceEpoch(value.toInt()),
      _ => null,
    },
    subscriptionInfo: info is Map
        ? SubscriptionInfo.fromJson(Map<String, Object?>.from(info))
        : null,
    selectedMap: switch (item['selectedMap']) {
      final Map value => {
        for (final entry in value.entries)
          entry.key.toString(): entry.value.toString(),
      },
      _ => const {},
    },
  );
}
