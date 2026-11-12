class SubscriptionProfile {
  const SubscriptionProfile({required this.configuration, required this.index});

  final Map<String, dynamic> configuration;
  final int index;

  String? get stableId {
    final value =
        configuration['id'] ?? configuration['uuid'] ?? configuration['tag'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  String get favoriteKey {
    final id = stableId;
    if (id != null) return 'id:$id';
    return 'fallback:$index:${name.trim().toLowerCase()}';
  }

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
    return 'Конфигурации';
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
      if (value['is_default'] == true) return 'default';
    }
    return 'ungrouped';
  }

  String? get description {
    final value = configuration['subtitle'] ??
        configuration['shortDescription'] ??
        configuration['description'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  int get sortOrder {
    final value = configuration['sortOrder'] ??
        configuration['sort_order'] ??
        configuration['sort'] ??
        configuration['order'];
    return _parseOrder(value) ?? index;
  }

  String? get groupDescription {
    final value = configuration['group'];
    if (value is! Map) return null;
    final description = value['description'];
    return description is String && description.trim().isNotEmpty
        ? description.trim()
        : null;
  }

  int? get groupSortOrder {
    final value = configuration['group'];
    if (value is! Map) return null;
    final order = value['sort'] ??
        value['sortOrder'] ??
        value['sort_order'] ??
        value['order'];
    return _parseOrder(order);
  }

  bool get groupIsDefault {
    final value = configuration['group'];
    return value is Map && value['is_default'] == true;
  }

  String? get groupIcon {
    final value = configuration['group'];
    final icon = value is Map ? value['icon'] : null;
    return icon is String && icon.trim().isNotEmpty ? icon.trim() : null;
  }

  bool get groupExpandedByDefault {
    final value = configuration['group'];
    if (value is! Map) return true;
    final expanded = value['defaultExpanded'] ?? value['expanded'];
    return expanded is bool ? expanded : true;
  }

  String? get icon {
    final value = configuration['icon'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  MapEntry<String, int>? get endpoint {
    final outbounds = configuration['outbounds'];
    if (outbounds is! List) return null;
    for (final outbound in outbounds.whereType<Map>()) {
      final settings = outbound['settings'];
      if (settings is! Map) continue;
      final candidates = [settings['vnext'], settings['servers']];
      for (final candidateList in candidates) {
        if (candidateList is! List) continue;
        for (final candidate in candidateList.whereType<Map>()) {
          final host = candidate['address'];
          final port = candidate['port'];
          if (host is String && host.isNotEmpty && port is num && port > 0) {
            return MapEntry(host, port.toInt());
          }
        }
      }
    }
    return null;
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
    runtimeConfiguration.remove('shortDescription');
    runtimeConfiguration.remove('description');
    runtimeConfiguration.remove('subtitle');
    runtimeConfiguration.remove('sortOrder');
    runtimeConfiguration.remove('sort_order');
    runtimeConfiguration.remove('sort');
    runtimeConfiguration.remove('order');
    runtimeConfiguration.remove('icon');
    return runtimeConfiguration;
  }
}

int? _parseOrder(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
