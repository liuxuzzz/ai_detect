import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks_client.dart';

import 'channel_proxy.dart';

/// One client per request owner. Configuring a channel never changes the
/// process-wide proxy, so concurrent channels can use different routes.
Future<http.Client> createUpstreamHttpClient(
  ChannelProxy proxy, {
  Duration connectionTimeout = const Duration(seconds: 45),
  SecurityContext? securityContext,
}) async {
  final error = proxy.validationError;
  if (error != null) throw FormatException(error);
  final native = HttpClient(context: securityContext)
    ..connectionTimeout = connectionTimeout;
  try {
    switch (proxy.type) {
      case 'http':
        final host = proxy.host.contains(':') ? '[${proxy.host}]' : proxy.host;
        native.findProxy = (_) => 'PROXY $host:${proxy.port}';
      case 'socks5':
        // Resolve only the proxy locally. Destination names go through SOCKS5.
        final address =
            InternetAddress.tryParse(proxy.host) ??
            (await InternetAddress.lookup(
              proxy.host,
            ).timeout(connectionTimeout)).first;
        native.findProxy = (_) => 'DIRECT';
        SocksTCPClient.assignToHttpClientWithSecureOptions(native, [
          ProxySettings(address, proxy.port),
        ], context: securityContext);
      default:
        native.findProxy = (_) => 'DIRECT';
    }
    return IOClient(native);
  } catch (_) {
    native.close(force: true);
    rethrow;
  }
}
