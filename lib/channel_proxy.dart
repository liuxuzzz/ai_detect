import 'dart:io';

class ChannelProxy {
  const ChannelProxy({
    this.type = 'none',
    this.host = '127.0.0.1',
    this.port = 7890,
  });

  final String type, host;
  final int port;
  bool get enabled => type != 'none';

  String? get validationError {
    if (!enabled) return null;
    if (type != 'http' && type != 'socks5') return '不支持的代理类型';
    if (host.isEmpty ||
        RegExp(r'[\s/;@?#]').hasMatch(host) ||
        (host.contains(':') && InternetAddress.tryParse(host) == null)) {
      return '请填写有效的代理主机，不包含协议或端口';
    }
    if (port < 1 || port > 65535) return '代理端口必须为 1–65535 的整数';
    return null;
  }

  factory ChannelProxy.fromMap(Map<String, Object?> row) => ChannelProxy(
    type: row['proxy_type'] as String? ?? 'none',
    host: row['proxy_host'] as String? ?? '127.0.0.1',
    port: (row['proxy_port'] as num?)?.toInt() ?? 7890,
  );

  Map<String, Object?> toMap() => {
    'proxy_type': type,
    'proxy_host': host,
    'proxy_port': port,
  };
}
