String normalizeCloudApiUrl(String value) {
  return value.trim().replaceFirst(RegExp(r'/+$'), '');
}
