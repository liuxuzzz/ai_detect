String numberText(num value, {int decimals = 1}) {
  final parts = value.toStringAsFixed(decimals).split('.');
  final whole = parts.first.replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (match) => '${match[1]},',
  );
  return parts.length == 1 ? whole : '$whole.${parts[1]}';
}

String tokenText(num value) => numberText(value, decimals: 0);

String cacheTokenText(int? value, {String suffix = ''}) =>
    value == null ? '未上报' : '${tokenText(value)}$suffix';

String cacheHitRateText(double? rate) =>
    rate == null ? 'N/A' : '${(rate * 100).toStringAsFixed(1)}%';

String secondsText(num milliseconds) =>
    '${numberText(milliseconds / 1000, decimals: 2)} s';
