class SubscriptionProfile {
  const SubscriptionProfile({required this.configuration, required this.index});

  final Map<String, dynamic> configuration;
  final int index;

  String get name {
    final remarks = configuration['remarks'];
    if (remarks is String && remarks.trim().isNotEmpty) return remarks.trim();

    final tag = configuration['tag'];
    if (tag is String && tag.trim().isNotEmpty) return tag.trim();

    return 'Сервер $index';
  }

  List<Map<String, dynamic>> get inbounds {
    final value = configuration['inbounds'];
    if (value is! List) return const [];

    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Map<String, dynamic> toRuntimeConfiguration() {
    return Map<String, dynamic>.from(configuration);
  }
}
