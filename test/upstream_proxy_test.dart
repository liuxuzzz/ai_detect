import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aijiance/agent_tools.dart';
import 'package:aijiance/channel_proxy.dart';
import 'package:aijiance/data.dart';
import 'package:aijiance/diagnostics_service.dart';
import 'package:aijiance/upstream_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socks5_proxy/socks_server.dart';

// All destinations are synthetic names. Success requires the configured proxy;
// a direct request cannot resolve them on the test machine.
void main() {
  test(
    'proxy validation and portable channel copies preserve configuration',
    () {
      const proxy = ChannelProxy(type: 'socks5', host: '127.0.0.1', port: 1080);
      const upstream = Upstream(
        id: 'u',
        name: 'u',
        baseUrl: 'x',
        apiKey: 'k',
        models: [],
        proxy: proxy,
      );
      final copied = upstream.copyWith(apiKey: 'refreshed');
      expect(Upstream.fromMap(copied.toMap()).proxy.toMap(), proxy.toMap());
      final old = upstream.toMap()
        ..removeWhere((key, _) => key.startsWith('proxy_'));
      expect(Upstream.fromMap(old).proxy.enabled, isFalse);
      expect(
        const ChannelProxy(
          type: 'http',
          host: 'http://localhost',
          port: 80,
        ).validationError,
        isNotNull,
      );
      expect(
        const ChannelProxy(type: 'socks5', port: 65536).validationError,
        isNotNull,
      );
      expect(
        const ChannelProxy(
          type: 'http',
          host: '::1',
          port: 8080,
        ).validationError,
        isNull,
      );
    },
  );

  for (final type in ['http', 'socks5']) {
    test(
      '$type routes models, connection checks, Agent turns through the proxy',
      () async {
        final received = <String>[];
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => origin.close(force: true));
        origin.listen((request) async {
          received.add(request.uri.path);
          final body = await utf8.decoder.bind(request).join();
          if (request.uri.path == '/v1/models') {
            request.response.write('{"data":[{"id":"test-model"}]}');
          } else {
            final data = jsonDecode(body) as Map;
            final firstRound =
                data['tools'] != null && (data['messages'] as List).length == 1;
            final delta = firstRound
                ? {
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'list-1',
                        'function': {
                          'name': 'list_html_files',
                          'arguments': '{}',
                        },
                      },
                    ],
                  }
                : {'content': 'OK'};
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.write(
              'data: ${jsonEncode({
                'choices': [
                  {'delta': delta},
                ],
              })}\n\ndata: [DONE]\n\n',
            );
          }
          await request.response.close();
        });
        final proxy = await _proxy(type, origin.port);
        final service = DiagnosticsService(
          tcpConnectProbe: (uri, _) async {
            expect(uri.host, '127.0.0.1');
            expect(uri.port, proxy.port);
            return 1;
          },
        );
        addTearDown(service.close);
        final upstream = Upstream(
          id: 'u',
          name: type,
          baseUrl: 'http://relay.proxy.test:${origin.port}/v1',
          apiKey: 'test-key',
          models: ['test-model'],
          selectedModel: 'test-model',
          proxy: proxy,
        );
        expect(await service.fetchModels(upstream: upstream), ['test-model']);
        expect((await service.testConnection(upstream: upstream)).ok, isTrue);
        final directory = await Directory.systemTemp.createTemp('agent-proxy-');
        addTearDown(() => directory.delete(recursive: true));
        final agent = await service.agent(
          upstream: upstream,
          prompt: defaultPelicanPrompt,
          runtime: AgentToolRuntime(directory),
          onTcpConnected: (_) {},
          onText: (_) {},
        );
        expect(agent.output, 'OK');
        expect(received, [
          '/v1/models',
          '/v1/chat/completions',
          '/v1/chat/completions',
          '/v1/chat/completions',
        ]);
      },
    );

    test(
      '$type tunnels HTTPS and validates the destination certificate',
      () async {
        final context = SecurityContext()
          ..useCertificateChain('test/fixtures/proxy_test_cert.pem')
          ..usePrivateKey('test/fixtures/proxy_test_key.pem');
        final origin = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          context,
        );
        addTearDown(() => origin.close(force: true));
        origin.listen((request) async {
          request.response.write('TLS through proxy');
          await request.response.close();
        });
        final proxy = await _proxy(type, origin.port);
        final trusted = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates('test/fixtures/proxy_test_ca.pem');
        final client = await createUpstreamHttpClient(
          proxy,
          securityContext: trusted,
        );
        addTearDown(client.close);
        final response = await client
            .get(Uri.parse('https://relay.proxy.test:${origin.port}/'))
            .timeout(const Duration(seconds: 5));
        expect(response.body, 'TLS through proxy');
      },
    );
  }

  test(
    'unreachable HTTP proxy fails without falling back to direct access',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var directRequests = 0;
      origin.listen((request) async {
        directRequests++;
        await request.response.close();
      });
      addTearDown(() => origin.close(force: true));
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();
      final client = await createUpstreamHttpClient(
        ChannelProxy(type: 'http', port: port),
      );
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:${origin.port}/')),
        throwsException,
      );
      expect(directRequests, 0);
    },
  );
}

Future<ChannelProxy> _proxy(String type, int originPort) async {
  if (type == 'socks5') {
    final proxy = SocksServer(
      lookup: (host, {type = InternetAddressType.any}) async {
        expect(host, 'relay.proxy.test');
        return [InternetAddress.loopbackIPv4];
      },
    );
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    await proxy.addServerSocket(listener);
    proxy.connections.listen((connection) => unawaited(connection.forward()));
    addTearDown(proxy.stop);
    return ChannelProxy(type: type, port: listener.port);
  }
  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final forward = HttpClient()..findProxy = (_) => 'DIRECT';
  addTearDown(() async {
    forward.close(force: true);
    await proxy.close(force: true);
  });
  proxy.listen((request) async {
    if (request.method == 'CONNECT') {
      final target = await Socket.connect(
        InternetAddress.loopbackIPv4,
        originPort,
      );
      final incoming = await request.response.detachSocket(writeHeaders: false);
      incoming.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await incoming.flush();
      unawaited(incoming.addStream(target).whenComplete(incoming.destroy));
      unawaited(target.addStream(incoming).whenComplete(target.destroy));
    } else {
      expect(request.uri.host, 'relay.proxy.test');
      final outgoing = await forward.openUrl(
        request.method,
        request.uri.replace(host: '127.0.0.1', port: originPort),
      );
      request.headers.forEach((name, values) {
        if (name != 'host') outgoing.headers.set(name, values);
      });
      await outgoing.addStream(request);
      final response = await outgoing.close();
      request.response.statusCode = response.statusCode;
      await request.response.addStream(response);
      await request.response.close();
    }
  });
  return ChannelProxy(type: type, port: proxy.port);
}
