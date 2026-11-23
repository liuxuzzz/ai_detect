import 'package:aijiance/cloud_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalization only trims whitespace and trailing slashes', () {
    expect(
      normalizeCloudApiUrl(' http://127.0.0.1:8081/ '),
      'http://127.0.0.1:8081',
    );
    expect(
      normalizeCloudApiUrl(' https://api.example.test/cloud/// '),
      'https://api.example.test/cloud',
    );
  });

  test('custom endpoints are preserved', () {
    for (final address in [
      '',
      'http://127.0.0.1:8080',
      'http://192.0.2.10:8081',
      'http://[2001:db8::1]:8081',
      'https://cloud.example.test:8080',
      'https://api.example.test',
      'http://192.0.2.10:8080/custom',
    ]) {
      expect(normalizeCloudApiUrl(address), address);
    }
  });
}
