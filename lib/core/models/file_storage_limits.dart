import 'package:equatable/equatable.dart';

class FileStorageLimits extends Equatable {
  const FileStorageLimits({
    required this.singleFileLimitBytes,
    required this.totalUploadsLimitBytes,
    required this.currentUsageBytes,
    required this.remainingBytes,
    required this.transferRateLimitBytesPerSecond,
  });

  factory FileStorageLimits.fromJson(Map<String, dynamic> json) {
    return FileStorageLimits(
      singleFileLimitBytes: (json['singleFileLimitBytes'] as num?)?.toInt() ?? 0,
      totalUploadsLimitBytes:
          (json['totalUploadsLimitBytes'] as num?)?.toInt() ?? 0,
      currentUsageBytes: (json['currentUsageBytes'] as num?)?.toInt() ?? 0,
      remainingBytes: (json['remainingBytes'] as num?)?.toInt() ?? 0,
      transferRateLimitBytesPerSecond:
          (json['transferRateLimitBytesPerSecond'] as num?)?.toInt() ?? 0,
    );
  }

  final int singleFileLimitBytes;
  final int totalUploadsLimitBytes;
  final int currentUsageBytes;
  final int remainingBytes;
  final int transferRateLimitBytesPerSecond;

  double get usedRatio {
    if (totalUploadsLimitBytes <= 0) {
      return 0;
    }

    return (currentUsageBytes / totalUploadsLimitBytes).clamp(0, 1);
  }

  @override
  List<Object?> get props => <Object?>[
        singleFileLimitBytes,
        totalUploadsLimitBytes,
        currentUsageBytes,
        remainingBytes,
        transferRateLimitBytesPerSecond,
      ];
}
