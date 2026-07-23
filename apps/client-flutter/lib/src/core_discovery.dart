part of '../main.dart';

const _intMusicServiceType = '_intmusic-core._tcp.local';
const _corePortRangeStart = 49330;
const _corePortRangeEnd = 49360;

class _DiscoveredCore {
  const _DiscoveredCore({
    required this.baseUrl,
    required this.source,
    this.name,
    this.serverId,
  });

  final String baseUrl;
  final String source;
  final String? name;
  final String? serverId;
}

Future<List<_DiscoveredCore>> _discoverIntMusicCores({
  String? hintBaseUrl,
}) async {
  final installed = await _verifyCoreCandidates(
    await _installedCoreCandidates(),
  );
  if (installed.isNotEmpty) {
    return installed;
  }

  final mdns = await _verifyCoreCandidates(await _discoverMdnsCores());
  if (mdns.isNotEmpty) {
    return mdns;
  }

  final directHosts = <String>{'127.0.0.1', 'localhost'};
  final hintHost = Uri.tryParse(hintBaseUrl ?? '')?.host;
  if (hintHost != null && hintHost.isNotEmpty) {
    directHosts.add(hintHost);
  }
  directHosts.addAll(await _localInterfaceHosts());

  final direct = await _verifyCoreCandidates(
    _portRangeCandidates(directHosts, 'local scan'),
  );
  if (direct.isNotEmpty) {
    return direct;
  }

  final lanHosts = await _lanSubnetHosts();
  return _verifyCoreCandidates(_portRangeCandidates(lanHosts, 'LAN scan'));
}

Future<List<_DiscoveredCore>> _installedCoreCandidates() async {
  if (!Platform.isWindows) {
    return const [];
  }
  final programData =
      (Platform.environment['ProgramData'] ??
              Platform.environment['PROGRAMDATA'])
          ?.trim();
  if (programData == null || programData.isEmpty) {
    return const [];
  }
  final endpointFile = File(
    '$programData\\IntMusic\\Core\\data\\core-endpoint.json',
  );
  try {
    final payload = _asMap(jsonDecode(await endpointFile.readAsString()));
    final baseUrl = payload['base_url']?.toString().trim();
    final uri = Uri.tryParse(baseUrl ?? '');
    if (uri == null ||
        uri.scheme != 'http' ||
        !uri.hasPort ||
        !_isLoopbackHost(uri.host)) {
      return const [];
    }
    return [_DiscoveredCore(baseUrl: uri.toString(), source: 'installed Core')];
  } catch (_) {
    return const [];
  }
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == '127.0.0.1' ||
      normalized == 'localhost' ||
      normalized == '::1';
}

List<_DiscoveredCore> _portRangeCandidates(
  Iterable<String> hosts,
  String source,
) {
  final candidates = <String, _DiscoveredCore>{};
  for (final host in hosts) {
    if (host.trim().isEmpty) {
      continue;
    }
    for (var port = _corePortRangeStart; port <= _corePortRangeEnd; port++) {
      final url = 'http://$host:$port';
      candidates.putIfAbsent(
        url,
        () => _DiscoveredCore(baseUrl: url, source: source),
      );
    }
  }
  return candidates.values.toList(growable: false);
}

Future<List<_DiscoveredCore>> _verifyCoreCandidates(
  Iterable<_DiscoveredCore> candidates,
) async {
  final verified = <_DiscoveredCore>[];
  final pending = candidates.toList(growable: false);
  const batchSize = 192;
  for (var offset = 0; offset < pending.length; offset += batchSize) {
    final batch = pending.skip(offset).take(batchSize).map((candidate) async {
      final status = await _tryLoadCoreStatus(candidate.baseUrl);
      if (status == null) {
        return null;
      }
      return _DiscoveredCore(
        baseUrl: candidate.baseUrl,
        source: candidate.source,
        name: status['display_name']?.toString() ?? status['name']?.toString(),
        serverId: status['server_id']?.toString(),
      );
    });
    for (final result in await Future.wait(batch)) {
      if (result != null) {
        verified.add(result);
      }
    }
    if (verified.isNotEmpty) {
      break;
    }
  }
  return verified;
}

Future<Set<String>> _localInterfaceHosts() async {
  final hosts = <String>{};
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  )) {
    for (final address in interface.addresses) {
      if (_isUsablePrivateIpv4(address.address)) {
        hosts.add(address.address);
      }
    }
  }
  return hosts;
}

Future<Set<String>> _lanSubnetHosts() async {
  final hosts = <String>{};
  for (final host in await _localInterfaceHosts()) {
    final parts = host.split('.');
    if (parts.length != 4) {
      continue;
    }
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
    for (var suffix = 1; suffix <= 254; suffix++) {
      hosts.add('$prefix.$suffix');
    }
  }
  return hosts;
}

bool _isUsablePrivateIpv4(String address) {
  final parts = address.split('.').map(int.tryParse).toList(growable: false);
  if (parts.length != 4 || parts.any((part) => part == null)) {
    return false;
  }
  final a = parts[0]!;
  final b = parts[1]!;
  if (a == 127 || a == 0 || a == 169 && b == 254) {
    return false;
  }
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

Future<List<_DiscoveredCore>> _discoverMdnsCores() async {
  final client = MDnsClient();
  final discovered = <String, _DiscoveredCore>{};
  try {
    await client.start();
    await for (final ptr in client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer(_intMusicServiceType),
      timeout: const Duration(seconds: 3),
    )) {
      final serviceName = ptr.domainName;
      final srv = await _firstRecord<SrvResourceRecord>(
        client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(serviceName),
          timeout: const Duration(seconds: 2),
        ),
      );
      if (srv == null) {
        continue;
      }

      final txt = await _firstRecord<TxtResourceRecord>(
        client.lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(serviceName),
          timeout: const Duration(seconds: 1),
        ),
      );
      final properties = _parseTxtProperties(txt?.text);
      final hosts = <String>{};
      await for (final address in client.lookup<IPAddressResourceRecord>(
        ResourceRecordQuery.addressIPv4(srv.target),
        timeout: const Duration(seconds: 2),
      )) {
        final host = address.address.address;
        hosts.add(host.contains(':') ? '[$host]' : host);
      }
      if (hosts.isEmpty) {
        hosts.add(srv.target.replaceAll(RegExp(r'\.$'), ''));
      }

      for (final host in hosts) {
        final url = 'http://$host:${srv.port}';
        discovered[url] = _DiscoveredCore(
          baseUrl: url,
          source: 'mDNS',
          name: properties['name'],
          serverId: properties['server_id'],
        );
      }
    }
  } catch (_) {
    // mDNS can be blocked by the OS firewall or mobile platform policies.
  } finally {
    client.stop();
  }
  return discovered.values.toList(growable: false);
}

Future<T?> _firstRecord<T>(Stream<T> stream) async {
  await for (final value in stream) {
    return value;
  }
  return null;
}

Map<String, String> _parseTxtProperties(String? text) {
  if (text == null || text.isEmpty) {
    return const {};
  }
  final result = <String, String>{};
  for (final chunk in text.split('\n')) {
    final separator = chunk.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    result[chunk.substring(0, separator).toLowerCase()] = chunk.substring(
      separator + 1,
    );
  }
  return result;
}

Future<Map<String, dynamic>?> _tryLoadCoreStatus(String baseUrl) async {
  try {
    final status = _asMap(
      await CoreApiClient(
        baseUrl,
        timeout: const Duration(milliseconds: 420),
      ).getJson('/status'),
    );
    if (_isIntMusicCoreStatus(status)) {
      return status;
    }
  } catch (_) {
    return null;
  }
  return null;
}

bool _isIntMusicCoreStatus(Map<String, dynamic> status) {
  return status['name'] == 'IntMusic Local Music Core' &&
      status['api_version'] == 'v1';
}
