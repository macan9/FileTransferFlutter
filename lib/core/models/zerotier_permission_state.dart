import 'package:equatable/equatable.dart';

class ZeroTierPermissionState extends Equatable {
  const ZeroTierPermissionState({
    required this.isGranted,
    required this.requiresManualSetup,
    required this.isFirewallSupported,
    this.summary,
  });

  const ZeroTierPermissionState.unknown()
      : isGranted = true,
        requiresManualSetup = false,
        isFirewallSupported = false,
        summary = null;

  final bool isGranted;
  final bool requiresManualSetup;
  final bool isFirewallSupported;
  final String? summary;

  ZeroTierPermissionState copyWith({
    bool? isGranted,
    bool? requiresManualSetup,
    bool? isFirewallSupported,
    String? summary,
    bool clearSummary = false,
  }) {
    return ZeroTierPermissionState(
      isGranted: isGranted ?? this.isGranted,
      requiresManualSetup: requiresManualSetup ?? this.requiresManualSetup,
      isFirewallSupported: isFirewallSupported ?? this.isFirewallSupported,
      summary: clearSummary ? null : summary ?? this.summary,
    );
  }

  @override
  List<Object?> get props => <Object?>[
        isGranted,
        requiresManualSetup,
        isFirewallSupported,
        summary,
      ];
}
