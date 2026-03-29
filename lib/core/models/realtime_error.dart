class RealtimeError implements Exception {
  const RealtimeError(this.message);

  final String message;

  @override
  String toString() => message;
}
