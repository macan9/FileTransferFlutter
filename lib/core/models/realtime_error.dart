class RealtimeError implements Exception {
  const RealtimeError(
    this.message, {
    this.statusCode,
    this.code,
    this.bootstrapRequired = false,
    this.bootstrapEndpoint,
    this.agentRegisterEndpoint,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final bool bootstrapRequired;
  final String? bootstrapEndpoint;
  final String? agentRegisterEndpoint;

  bool get requiresBootstrapRecovery =>
      bootstrapRequired || code == 'DEVICE_NOT_FOUND';

  @override
  String toString() => message;
}
