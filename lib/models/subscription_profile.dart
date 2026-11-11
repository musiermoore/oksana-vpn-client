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

  String get groupName {
    final value = configuration['group'];
    if (value is Map) {
      final name = value['name'];
      if (name is String && name.trim().isNotEmpty) return name.trim();
    }
    return 'Без группы';
  }

  String get groupKey {
    final value = configuration['group'];
    if (value is Map) {
      final id = value['id'];
      if (id != null) return 'id:${id.toString()}';
      final name = value['name'];
      if (name is String && name.trim().isNotEmpty) {
        return 'name:${name.trim()}';
      }
    }
    return 'ungrouped';
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
    final runtimeConfiguration = Map<String, dynamic>.from(configuration)
      ..remove('group');
    return runtimeConfiguration;
  }
}
