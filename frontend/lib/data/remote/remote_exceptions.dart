class RemoteHttpException implements Exception {
  final int statusCode;
  final String message;
  final String? responseBody;

  RemoteHttpException({
    required this.statusCode,
    required this.message,
    this.responseBody,
  });

  @override
  String toString() => 'RemoteHttpException($statusCode): $message';
}

class RemoteParseException implements Exception {
  final String message;
  final String? responseBody;

  RemoteParseException({required this.message, this.responseBody});

  @override
  String toString() => 'RemoteParseException: $message';
}