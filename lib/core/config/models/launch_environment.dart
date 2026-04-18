import 'package:equatable/equatable.dart';

enum LaunchMode { dev, pro }

class LaunchEnvironment extends Equatable {
  const LaunchEnvironment({
    required this.mode,
    required this.devServerUrl,
    required this.proServerUrl,
  });

  factory LaunchEnvironment.fromJson(Map<String, dynamic> json) {
    return LaunchEnvironment(
      mode: _parseMode(json['mode']?.toString()),
      devServerUrl: json['devServerUrl']?.toString() ?? '',
      proServerUrl: json['proServerUrl']?.toString() ?? '',
    );
  }

  final LaunchMode mode;
  final String devServerUrl;
  final String proServerUrl;

  String get activeServerUrl =>
      mode == LaunchMode.pro ? proServerUrl : devServerUrl;

  @override
  List<Object?> get props => <Object?>[mode, devServerUrl, proServerUrl];

  static LaunchMode _parseMode(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'pro':
        return LaunchMode.pro;
      case 'dev':
      default:
        return LaunchMode.dev;
    }
  }
}
