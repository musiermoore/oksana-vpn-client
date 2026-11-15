import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../models/vpn_routing_settings.dart';
import '../services/routing_template_importer.dart';

const _routingImportChannel = MethodChannel('oksanavpn/deep_links');

enum _RoutingAddMethod { clipboard, link, manual }

enum _RoutingManualMethod { interface, json }

class RoutingSettingsScreen extends StatefulWidget {
  const RoutingSettingsScreen({
    super.key,
    required this.settings,
  });

  final VpnRoutingSettings settings;

  @override
  State<RoutingSettingsScreen> createState() => _RoutingSettingsScreenState();
}

class _RoutingSettingsScreenState extends State<RoutingSettingsScreen> {
  late bool _enabled = widget.settings.enabled;
  late final List<RoutingTemplate> _templates =
      widget.settings.templates.isEmpty
          ? [widget.settings.activeTemplate]
          : List.of(widget.settings.templates);
  late String _activeTemplateId = widget.settings.activeTemplate.id;
  late final String _initialSettings;
  bool _allowExit = false;
  bool _confirmingExit = false;
  bool _importingTemplate = false;

  @override
  void initState() {
    super.initState();
    _initialSettings = _currentSettings.encode();
  }

  VpnRoutingSettings get _currentSettings => VpnRoutingSettings(
        enabled: _enabled,
        templates: List.unmodifiable(_templates),
        activeTemplateId: _activeTemplateId,
      );

  bool get _hasChanges => _currentSettings.encode() != _initialSettings;

  RoutingTemplate _templateById(String id) => _templates.firstWhere(
        (template) => template.id == id,
        orElse: () => _templates.first,
      );

  void _replaceTemplate(RoutingTemplate value) {
    setState(() {
      final index =
          _templates.indexWhere((template) => template.id == value.id);
      if (index >= 0) _templates[index] = value;
    });
  }

  Future<RoutingTemplate?> _createTemplate() async {
    final name = await _askTemplateName(title: 'Новый шаблон');
    if (name == null || !mounted) return null;
    final template = RoutingTemplate(
      id: _newId(),
      name: name,
      defaultAction: RoutingAction.proxy,
    );
    setState(() {
      _templates.add(template);
      _activeTemplateId = template.id;
    });
    return template;
  }

  Future<void> _renameTemplate(String id) async {
    final template = _templateById(id);
    final name = await _askTemplateName(
      title: 'Переименовать шаблон',
      initialValue: template.name,
    );
    if (name == null || !mounted) return;
    _replaceTemplate(template.copyWith(name: name));
  }

  Future<void> _duplicateTemplate(String id) async {
    final template = _templateById(id);
    final name = await _askTemplateName(
      title: 'Копировать шаблон',
      initialValue: '${template.name} — копия',
    );
    if (name == null || !mounted) return;
    final copy = template.copyWith(id: _newId(), name: name);
    setState(() {
      _templates.add(copy);
      _activeTemplateId = copy.id;
    });
  }

  Future<String?> _askTemplateName({
    required String title,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 48,
          decoration: const InputDecoration(labelText: 'Название'),
          onSubmitted: (value) {
            final clean = value.trim();
            if (clean.isNotEmpty) Navigator.of(context).pop(clean);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final clean = controller.text.trim();
              if (clean.isNotEmpty) Navigator.of(context).pop(clean);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _deleteTemplate(String id) async {
    final template = _templateById(id);
    final isLastTemplate = _templates.length == 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить шаблон?'),
        content: Text(isLastTemplate
            ? '«${template.name}» будет удалён. После этого появится пустой шаблон «Мои правила».'
            : '«${template.name}» будет удалён.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _templates.removeWhere((item) => item.id == id);
      if (_templates.isEmpty) {
        final replacement = RoutingTemplate(
          id: _newId(),
          name: 'Мои правила',
        );
        _templates.add(replacement);
        _activeTemplateId = replacement.id;
      } else if (_activeTemplateId == id) {
        _activeTemplateId = _templates.first.id;
      }
    });
  }

  Future<void> _openTemplate(String id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _RoutingTemplateDetailScreen(
          template: _templateById(id),
          isActive: _activeTemplateId == id,
          onChanged: _replaceTemplate,
          onSetActive: () => setState(() => _activeTemplateId = id),
        ),
      ),
    );
  }

  Future<void> _importFromClipboard() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final raw = clipboard?.text?.trim() ?? '';
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Буфер обмена пуст.')),
      );
      return;
    }
    await _importRaw(raw);
  }

  Future<void> _openLinkImport() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const _RoutingLinkImportScreen(),
      ),
    );
    if (raw == null || !mounted) return;
    await _importRaw(raw);
  }

  Future<void> _importRaw(String raw) async {
    setState(() => _importingTemplate = true);
    try {
      final source = await RoutingTemplateImporter.resolveInput(raw);
      if (!mounted) return;
      final imported = RoutingTemplateImporter.parse(source);
      final template = imported.template.copyWith(
        id: _newId(),
        name: _uniqueName(imported.template.name),
      );
      setState(() {
        _templates.add(template);
        _activeTemplateId = template.id;
        _importingTemplate = false;
      });
      if (imported.warnings.isNotEmpty && mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Шаблон импортирован'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Добавлено правил: ${template.rules.length}.'),
                  if (template.geoipUrl != null ||
                      template.geositeUrl != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'При подключении будут загружены базы: ${[
                        if (template.geoipUrl != null) 'GeoIP',
                        if (template.geositeUrl != null) 'GeoSite',
                      ].join(' и ')}.',
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                      'Некоторые параметры исходного шаблона не поддерживаются:'),
                  const SizedBox(height: 6),
                  for (final warning in imported.warnings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $warning'),
                    ),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Понятно'),
              ),
            ],
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Импортировано правил: ${template.rules.length}.')),
        );
      }
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted && _importingTemplate) {
        setState(() => _importingTemplate = false);
      }
    }
  }

  Future<bool> _editTemplateJson(String templateId) async {
    final template = _templateById(templateId);
    final imported = await showDialog<RoutingTemplateImportResult>(
      context: context,
      builder: (_) => _RoutingTemplateJsonDialog(
        initialJson: RoutingTemplateImporter.exportXrayJson(template),
      ),
    );
    if (imported == null || !mounted) return false;

    _replaceTemplate(imported.template.copyWith(id: templateId));
    if (imported.warnings.isNotEmpty && mounted) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('JSON применён с ограничениями'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final warning in imported.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('• $warning'),
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Понятно'),
            ),
          ],
        ),
      );
    }
    return true;
  }

  String _uniqueName(String requested) {
    final existing = _templates.map((template) => template.name).toSet();
    if (!existing.contains(requested)) return requested;
    var suffix = 2;
    while (existing.contains('$requested ($suffix)')) {
      suffix++;
    }
    return '$requested ($suffix)';
  }

  String _templateSummary(RoutingTemplate template) {
    final parts = ['${template.rules.length} правил'];
    final geoData = [
      if (template.geoipUrl != null) 'GeoIP',
      if (template.geositeUrl != null) 'GeoSite',
    ];
    if (geoData.isNotEmpty) parts.add(geoData.join(' + '));
    return parts.join(' · ');
  }

  Future<void> _openAddOptions() async {
    final method = await Navigator.of(context).push<_RoutingAddMethod>(
      MaterialPageRoute<_RoutingAddMethod>(
        builder: (_) => const _RoutingAddMethodScreen(),
      ),
    );
    if (!mounted) return;
    switch (method) {
      case _RoutingAddMethod.clipboard:
        await _importFromClipboard();
        break;
      case _RoutingAddMethod.link:
        await _openLinkImport();
        break;
      case _RoutingAddMethod.manual:
        await _openManualOptions();
        break;
      case null:
        break;
    }
  }

  Future<void> _openManualOptions() async {
    final method = await Navigator.of(context).push<_RoutingManualMethod>(
      MaterialPageRoute<_RoutingManualMethod>(
        builder: (_) => const _RoutingManualMethodScreen(),
      ),
    );
    if (!mounted) return;
    if (method == null) return;
    final previousActiveId = _activeTemplateId;
    final template = await _createTemplate();
    if (template == null || !mounted) return;
    if (method == _RoutingManualMethod.interface) {
      await _openTemplate(template.id);
    } else {
      final applied = await _editTemplateJson(template.id);
      if (!applied && mounted) {
        setState(() {
          _templates.removeWhere((item) => item.id == template.id);
          _activeTemplateId = previousActiveId;
        });
      }
    }
  }

  void _save() {
    _finish(_currentSettings);
  }

  void _finish([VpnRoutingSettings? result]) {
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  Future<void> _confirmDiscard() async {
    if (_confirmingExit) return;
    _confirmingExit = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Не сохранены изменения'),
        content: const Text('Выйти без сохранения изменений маршрутизации?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Остаться')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Выйти')),
        ],
      ),
    );
    _confirmingExit = false;
    if (discard == true && mounted) _finish();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PopScope<VpnRoutingSettings>(
      canPop: _allowExit || !_hasChanges,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_allowExit) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: theme.scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(
              height: 1,
              thickness: 1,
              color: theme.dividerColor,
            ),
          ),
          centerTitle: false,
          leadingWidth: 48,
          titleSpacing: 0,
          title: Text(
            'Маршрутизация',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: IconButton(
                tooltip: _importingTemplate
                    ? 'Загружаем шаблон…'
                    : 'Добавить шаблон',
                onPressed: _importingTemplate ? null : _openAddOptions,
                color: colors.primary,
                icon: _importingTemplate
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary,
                        ),
                      )
                    : const Icon(Icons.add_rounded, size: 26),
              ),
            ),
          ],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                    children: [
                      SwitchListTile.adaptive(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 4),
                        value: _enabled,
                        onChanged: (value) => setState(() => _enabled = value),
                        title: const Text('Свои правила'),
                        subtitle: Text(_enabled
                            ? 'TUN: весь трафик · Proxy: через локальный прокси'
                            : 'Выключены · действует VPN-конфигурация'),
                      ),
                      const SizedBox(height: 12),
                      const Text('Шаблоны',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      for (final template in _templates)
                        Card(
                          color: template.id == _activeTemplateId
                              ? colors.primary.withValues(alpha: 0.08)
                              : null,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: BorderSide(
                              color: template.id == _activeTemplateId
                                  ? AppTheme.primaryPressed
                                  : colors.outlineVariant,
                              width: template.id == _activeTemplateId ? 2 : 1,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            onTap: () =>
                                setState(() => _activeTemplateId = template.id),
                            leading: Icon(
                              template.id == _activeTemplateId
                                  ? Icons.rule_folder_rounded
                                  : Icons.folder_outlined,
                              color: template.id == _activeTemplateId
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                            title: Text(
                              template.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(_templateSummary(template)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  template.id == _activeTemplateId
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: template.id == _activeTemplateId
                                      ? colors.primary
                                      : colors.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                PopupMenuButton<String>(
                                  tooltip: 'Действия с шаблоном',
                                  onSelected: (value) {
                                    switch (value) {
                                      case 'edit':
                                        _openTemplate(template.id);
                                        break;
                                      case 'rename':
                                        _renameTemplate(template.id);
                                        break;
                                      case 'duplicate':
                                        _duplicateTemplate(template.id);
                                        break;
                                      case 'delete':
                                        _deleteTemplate(template.id);
                                        break;
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(
                                      value: 'edit',
                                      child: Text('Редактировать'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'rename',
                                      child: Text('Переименовать'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'duplicate',
                                      child: Text('Создать копию'),
                                    ),
                                    const PopupMenuDivider(),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Удалить'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (_templates.isEmpty)
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child:
                                Text('Добавьте первый шаблон маршрутизации.'),
                          ),
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _hasChanges ? _save : null,
                        child: Text(
                            _hasChanges ? 'Сохранить изменения' : 'Сохранено'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoutingTemplateDetailScreen extends StatefulWidget {
  const _RoutingTemplateDetailScreen({
    required this.template,
    required this.isActive,
    required this.onChanged,
    required this.onSetActive,
  });

  final RoutingTemplate template;
  final bool isActive;
  final ValueChanged<RoutingTemplate> onChanged;
  final VoidCallback onSetActive;

  @override
  State<_RoutingTemplateDetailScreen> createState() =>
      _RoutingTemplateDetailScreenState();
}

class _RoutingTemplateDetailScreenState
    extends State<_RoutingTemplateDetailScreen> {
  late RoutingTemplate _template = widget.template;
  late bool _isActive = widget.isActive;

  void _update(RoutingTemplate value) {
    setState(() => _template = value);
    widget.onChanged(value);
  }

  Future<void> _addRule(RoutingAction action) async {
    final rule = await showDialog<VpnRoutingRule>(
      context: context,
      builder: (_) => _AddRoutingRuleDialog(initialAction: action),
    );
    if (rule == null || !mounted) return;
    final duplicate = _template.rules.any((existing) =>
        existing.type == rule.type &&
        existing.value.toLowerCase() == rule.value.toLowerCase() &&
        existing.action == rule.action);
    if (duplicate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Такое правило уже есть в шаблоне.')),
      );
      return;
    }
    _update(_template.copyWith(rules: [..._template.rules, rule]));
  }

  void _removeRule(VpnRoutingRule rule) {
    final rules = List<VpnRoutingRule>.of(_template.rules)
      ..removeWhere((candidate) => identical(candidate, rule));
    _update(_template.copyWith(rules: rules));
  }

  Future<void> _editRule(VpnRoutingRule original) async {
    final structured = original.domains.isNotEmpty ||
        original.ips.isNotEmpty ||
        original.ports.isNotEmpty ||
        original.networks.isNotEmpty ||
        original.protocols.isNotEmpty;
    final updated = await showDialog<VpnRoutingRule>(
      context: context,
      builder: (_) => structured
          ? _EditStructuredRuleDialog(rule: original)
          : _AddRoutingRuleDialog(
              initialAction: original.action,
              rule: original,
            ),
    );
    if (updated == null || !mounted) return;
    final rules = List<VpnRoutingRule>.of(_template.rules);
    final index = rules.indexWhere((rule) => identical(rule, original));
    if (index < 0) return;
    rules[index] = updated;
    _update(_template.copyWith(rules: rules));
  }

  void _reorderRules(RoutingAction action, int oldIndex, int newIndex) {
    final group =
        _template.rules.where((rule) => rule.action == action).toList();
    if (oldIndex < 0 || oldIndex >= group.length || newIndex < 0) return;
    final rule = group.removeAt(oldIndex);
    group.insert(newIndex.clamp(0, group.length), rule);
    var groupIndex = 0;
    final reordered = _template.rules
        .map((item) => item.action == action ? group[groupIndex++] : item)
        .toList(growable: false);
    _update(_template.copyWith(rules: reordered));
  }

  Future<void> _editJson() async {
    final imported = await showDialog<RoutingTemplateImportResult>(
      context: context,
      builder: (_) => _RoutingTemplateJsonDialog(
        initialJson: RoutingTemplateImporter.exportXrayJson(_template),
      ),
    );
    if (imported == null || !mounted) return;
    _update(imported.template.copyWith(id: _template.id));
    if (imported.warnings.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('JSON применён с ограничениями'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final warning in imported.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('• $warning'),
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Понятно'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _editDnsSettings() async {
    final result = await showDialog<_RoutingDnsSettingsResult>(
      context: context,
      builder: (_) => _RoutingDnsSettingsDialog(template: _template),
    );
    if (result == null || !mounted) return;
    final updated = _template.copyWith(
      dnsSettings: result.dnsSettings,
      clearDnsSettings: result.replaceDnsServers && result.dnsSettings == null,
      clearXrayDnsConfig: result.replaceDnsServers,
      fakeDnsEnabled: result.fakeDnsEnabled,
    );
    _update(updated);
  }

  Future<void> _applyPreset(VpnRoutingMode mode) async {
    if (_template.rules.isNotEmpty) {
      final throughVpn = mode == VpnRoutingMode.vpnOnlyListed;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Применить режим?'),
          content: Text(throughVpn
              ? 'Все правила шаблона будут отправлять трафик через VPN. Остальной трафик пойдёт напрямую после проверки правил VPN-профиля.'
              : 'Все правила шаблона будут отправлять трафик напрямую. Остальной трафик пойдёт через VPN после проверки правил VPN-профиля.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Применить'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final defaultAction = mode == VpnRoutingMode.vpnExceptListed
        ? RoutingAction.proxy
        : RoutingAction.direct;
    final listedAction = mode == VpnRoutingMode.vpnExceptListed
        ? RoutingAction.direct
        : RoutingAction.proxy;
    _update(_template.copyWith(
      defaultAction: defaultAction,
      rules: _template.rules
          .map((rule) => VpnRoutingRule(
                type: rule.type,
                value: rule.value,
                action: listedAction,
                label: rule.label,
                domains: rule.domains,
                ips: rule.ips,
                ports: rule.ports,
                networks: rule.networks,
                protocols: rule.protocols,
              ))
          .toList(growable: false),
    ));
  }

  Widget _ruleSection(
    RoutingAction action,
    String title,
    IconData icon,
  ) {
    final accent = Theme.of(context).colorScheme.primary;
    final rules =
        _template.rules.where((rule) => rule.action == action).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 0, 6),
          child: Row(
            children: [
              Icon(icon, color: accent, size: 19),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$title · ${rules.length}',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Добавить правило: $title',
                visualDensity: VisualDensity.compact,
                onPressed: () => _addRule(action),
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
        ),
        if (rules.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                'В этом разделе пока нет правил.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          )
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: rules.length,
              // Keep onReorder for the project's Flutter 3.35 minimum.
              // ignore: deprecated_member_use
              onReorder: (oldIndex, newIndex) =>
                  _reorderRules(action, oldIndex, newIndex),
              itemBuilder: (context, index) {
                final rule = rules[index];
                return Column(
                  key: ObjectKey(rule),
                  children: [
                    _RoutingRuleTile(
                      rule: rule,
                      dragIndex: index,
                      onEdit: () => _editRule(rule),
                      onRemove: () => _removeRule(rule),
                    ),
                    if (index + 1 < rules.length) const Divider(height: 1),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
            height: 1,
            thickness: 1,
            color: theme.dividerColor,
          ),
        ),
        centerTitle: false,
        leadingWidth: 48,
        titleSpacing: 0,
        title: Text(
          _template.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium
              ?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: _isActive ? 'Активный шаблон' : 'Использовать шаблон',
            onPressed: () {
              widget.onSetActive();
              setState(() => _isActive = true);
            },
            icon: Icon(
              _isActive
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: _isActive ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
          IconButton(
            tooltip: 'Добавить правило',
            onPressed: () => _addRule(_template.defaultAction),
            icon: const Icon(Icons.add_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: 'Действия шаблона',
            onSelected: (value) {
              switch (value) {
                case 'json':
                  _editJson();
                  break;
                case 'vpn_except':
                  _applyPreset(VpnRoutingMode.vpnExceptListed);
                  break;
                case 'vpn_only':
                  _applyPreset(VpnRoutingMode.vpnOnlyListed);
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'json', child: Text('Редактировать JSON')),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'vpn_except',
                child: Text('Всё через VPN, кроме списка'),
              ),
              PopupMenuItem(
                value: 'vpn_only',
                child: Text('Через VPN только список'),
              ),
            ],
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  children: [
                    Card(
                      child: ListTile(
                        leading: Icon(Icons.dns_rounded, color: colors.primary),
                        title: const Text('DNS и FakeDNS'),
                        subtitle: Text(_dnsSummary(_template)),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _editDnsSettings,
                      ),
                    ),
                    if (_template.geoipUrl != null ||
                        _template.geositeUrl != null)
                      Card(
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.storage_rounded,
                              color: colors.primary),
                          title: Text('Внешние базы: ${[
                            if (_template.geoipUrl != null) 'GeoIP',
                            if (_template.geositeUrl != null) 'GeoSite',
                          ].join(' и ')}'),
                          subtitle: const Text('Загружаются при подключении'),
                        ),
                      ),
                    _ruleSection(
                      RoutingAction.block,
                      'Блокировать',
                      Icons.block_rounded,
                    ),
                    _ruleSection(
                      RoutingAction.proxy,
                      'Через VPN',
                      Icons.shield_rounded,
                    ),
                    _ruleSection(
                      RoutingAction.direct,
                      'Напрямую',
                      Icons.arrow_outward_rounded,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Остальной трафик',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _actionChip(
                          RoutingAction.proxy,
                          'Через VPN',
                          Icons.shield_rounded,
                        ),
                        _actionChip(
                          RoutingAction.direct,
                          'Напрямую',
                          Icons.arrow_outward_rounded,
                        ),
                        _actionChip(
                          RoutingAction.block,
                          'Блокировать',
                          Icons.block_rounded,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Это действие используется, если ни одно правило не совпало. Затем проверяются правила VPN-профиля.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                    if (_template.domainStrategy != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Стратегия доменов: ${_template.domainStrategy}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('К шаблонам'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionChip(
    RoutingAction action,
    String label,
    IconData icon,
  ) {
    return _RoutingChoiceChip(
      label: label,
      icon: icon,
      selected: _template.defaultAction == action,
      onSelected: () => _update(_template.copyWith(defaultAction: action)),
    );
  }

  String _dnsSummary(RoutingTemplate template) {
    final dns = template.dnsSettings;
    final parts = <String>[];
    if (template.xrayDnsConfig == null) {
      final remote = _dnsProviderFor(
        dns?.remoteProvider,
        dns?.remoteServer,
        dns?.remoteBootstrapIp,
      );
      final domestic = _dnsProviderFor(
        dns?.domesticProvider,
        dns?.domesticServer,
        dns?.domesticBootstrapIp,
      );
      parts.add('Через VPN: ${_dnsProviderLabel(remote)}');
      parts.add('Напрямую: ${_dnsProviderLabel(domestic)}');
    }
    if (dns?.hosts.isNotEmpty == true) {
      parts.add('Записей hosts: ${dns!.hosts.length}');
    }
    if (template.xrayDnsConfig != null && parts.isEmpty) {
      parts.add('DNS-серверы указаны в JSON Xray');
    }
    parts.add(template.usesFakeDns ? 'FakeDNS включён' : 'FakeDNS выключен');
    return parts.join(' · ');
  }
}

class _RoutingDnsSettingsResult {
  const _RoutingDnsSettingsResult({
    required this.dnsSettings,
    required this.fakeDnsEnabled,
    required this.replaceDnsServers,
  });

  final RoutingDnsSettings? dnsSettings;
  final bool fakeDnsEnabled;
  final bool replaceDnsServers;
}

class _RoutingDnsSettingsDialog extends StatefulWidget {
  const _RoutingDnsSettingsDialog({required this.template});

  final RoutingTemplate template;

  @override
  State<_RoutingDnsSettingsDialog> createState() =>
      _RoutingDnsSettingsDialogState();
}

class _RoutingDnsSettingsDialogState extends State<_RoutingDnsSettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  late RoutingDnsProvider _remoteProvider = _dnsProviderFor(
    widget.template.dnsSettings?.remoteProvider,
    widget.template.dnsSettings?.remoteServer,
    widget.template.dnsSettings?.remoteBootstrapIp,
  );
  late RoutingDnsProvider _domesticProvider = _dnsProviderFor(
    widget.template.dnsSettings?.domesticProvider,
    widget.template.dnsSettings?.domesticServer,
    widget.template.dnsSettings?.domesticBootstrapIp,
  );
  late final _remoteServer = TextEditingController(
    text: widget.template.dnsSettings?.remoteServer,
  );
  late final _remoteBootstrapIp = TextEditingController(
    text: widget.template.dnsSettings?.remoteBootstrapIp,
  );
  late final _domesticServer = TextEditingController(
    text: widget.template.dnsSettings?.domesticServer,
  );
  late final _domesticBootstrapIp = TextEditingController(
    text: widget.template.dnsSettings?.domesticBootstrapIp,
  );
  late bool _fakeDns = widget.template.usesFakeDns;

  bool get _canEditServers =>
      widget.template.xrayDnsConfig == null ||
      widget.template.dnsSettings != null;

  @override
  void dispose() {
    _remoteServer.dispose();
    _remoteBootstrapIp.dispose();
    _domesticServer.dispose();
    _domesticBootstrapIp.dispose();
    super.dispose();
  }

  String? _validateServer(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return 'Укажите IP-адрес или HTTPS-ссылку DoH.';
    final uri = Uri.tryParse(value);
    if (uri != null &&
        uri.scheme.toLowerCase() == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      return null;
    }
    if (InternetAddress.tryParse(value) != null) return null;
    return 'Укажите IP-адрес или HTTPS-ссылку DoH.';
  }

  String? _validateIp(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty || InternetAddress.tryParse(value) != null) return null;
    return 'Укажите корректный IP-адрес.';
  }

  void _submit() {
    if (_canEditServers && !_formKey.currentState!.validate()) return;
    final oldHosts = widget.template.dnsSettings?.hosts ?? const {};
    final remote = _dnsValuesFor(
      _remoteProvider,
      _remoteServer.text,
      _remoteBootstrapIp.text,
    );
    final domestic = _dnsValuesFor(
      _domesticProvider,
      _domesticServer.text,
      _domesticBootstrapIp.text,
    );
    final settings = _canEditServers
        ? RoutingDnsSettings(
            remoteProvider: _remoteProvider,
            remoteServer: remote.$1,
            remoteBootstrapIp: remote.$2,
            domesticProvider: _domesticProvider,
            domesticServer: domestic.$1,
            domesticBootstrapIp: domestic.$2,
            hosts: oldHosts,
          )
        : widget.template.dnsSettings;
    Navigator.of(context).pop(_RoutingDnsSettingsResult(
      dnsSettings: settings != null && settings.hasSettings ? settings : null,
      fakeDnsEnabled: _fakeDns,
      replaceDnsServers: _canEditServers,
    ));
  }

  String? _optionalText(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  (String?, String?) _dnsValuesFor(
    RoutingDnsProvider provider,
    String server,
    String bootstrapIp,
  ) {
    if (provider == RoutingDnsProvider.internal) return (null, null);
    final preset = RoutingDnsProviderPreset.forProvider(provider);
    if (preset != null) return (preset.server, preset.bootstrapIp);
    return (_optionalText(server), _optionalText(bootstrapIp));
  }

  void _selectProvider(bool remote, RoutingDnsProvider provider) {
    final preset = RoutingDnsProviderPreset.forProvider(provider);
    if (preset != null) {
      (remote ? _remoteServer : _domesticServer).text = preset.server;
      (remote ? _remoteBootstrapIp : _domesticBootstrapIp).text =
          preset.bootstrapIp;
    }
    setState(() {
      if (remote) {
        _remoteProvider = provider;
      } else {
        _domesticProvider = provider;
      }
    });
  }

  Widget _providerField({required bool remote}) {
    final provider = remote ? _remoteProvider : _domesticProvider;
    final title = remote ? 'DNS через VPN' : 'DNS для прямого подключения';
    final serverController = remote ? _remoteServer : _domesticServer;
    final bootstrapController =
        remote ? _remoteBootstrapIp : _domesticBootstrapIp;
    final preset = RoutingDnsProviderPreset.forProvider(provider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        DropdownButtonFormField<RoutingDnsProvider>(
          initialValue: provider,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Провайдер DNS',
            border: OutlineInputBorder(),
          ),
          items: RoutingDnsProvider.values
              .map((item) => DropdownMenuItem(
                    value: item,
                    child: Text(_dnsProviderLabel(item)),
                  ))
              .toList(growable: false),
          onChanged: (value) {
            if (value != null) _selectProvider(remote, value);
          },
        ),
        if (provider == RoutingDnsProvider.internal) ...[
          const SizedBox(height: 6),
          Text(
            'Использовать DNS-серверы из текущего VPN-профиля.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ] else if (preset != null) ...[
          const SizedBox(height: 6),
          Text(
            '${preset.server}\nДля системного DNS используется ${preset.bootstrapIp}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ] else ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: serverController,
            decoration: const InputDecoration(
              labelText: 'IP-адрес или HTTPS-ссылка DoH',
              hintText: 'https://dns.example/dns-query или 9.9.9.9',
            ),
            validator: _validateServer,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: bootstrapController,
            decoration: const InputDecoration(
              labelText: 'IP для поиска DoH-сервера',
              hintText: 'Необязательно, например 9.9.9.9',
            ),
            validator: _validateIp,
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('DNS и FakeDNS'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_canEditServers) ...[
                  Text(
                    'Выберите отдельный DNS для сайтов через VPN и для прямого подключения.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  _providerField(remote: true),
                  const SizedBox(height: 18),
                  _providerField(remote: false),
                ] else ...[
                  Text(
                    'Серверы DNS заданы в импортированном Xray JSON. Изменить их можно через «Редактировать JSON».',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Настройки применяются к DNS-запросам, которые проходят через Xray. В режиме «Прокси» приложения должны отправлять DNS через локальный прокси.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Использовать FakeDNS'),
                  subtitle: const Text(
                    'Подменять DNS-ответы виртуальными IP, чтобы Xray мог восстановить домен.',
                  ),
                  value: _fakeDns,
                  onChanged: (value) => setState(() => _fakeDns = value),
                ),
                if (_fakeDns) ...[
                  const SizedBox(height: 4),
                  Text(
                    'FakeDNS может оставить виртуальные адреса в системном кеше, а правила по IP могут видеть эти адреса вместо реальных.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}

String _dnsProviderLabel(RoutingDnsProvider provider) => switch (provider) {
      RoutingDnsProvider.internal => 'Внутренний (из профиля)',
      RoutingDnsProvider.google => 'Google',
      RoutingDnsProvider.cloudflare => 'Cloudflare',
      RoutingDnsProvider.quad9 => 'Quad9',
      RoutingDnsProvider.adguard => 'AdGuard',
      RoutingDnsProvider.custom => 'Свой DNS',
    };

RoutingDnsProvider _dnsProviderFor(
  RoutingDnsProvider? provider,
  String? server,
  String? bootstrapIp,
) {
  if (provider != null) return provider;
  final value = (server ?? bootstrapIp ?? '').toLowerCase();
  if (value.contains('dns.google') ||
      value.contains('8.8.8.8') ||
      value.contains('8.8.4.4')) {
    return RoutingDnsProvider.google;
  }
  if (value.contains('cloudflare-dns.com') ||
      value.contains('1.1.1.1') ||
      value.contains('1.0.0.1')) {
    return RoutingDnsProvider.cloudflare;
  }
  if (value.contains('dns.quad9.net') ||
      value.contains('9.9.9.9') ||
      value.contains('149.112.112.112')) {
    return RoutingDnsProvider.quad9;
  }
  if (value.contains('adguard-dns.com') ||
      value.contains('94.140.14.14') ||
      value.contains('94.140.15.15')) {
    return RoutingDnsProvider.adguard;
  }
  return server == null
      ? RoutingDnsProvider.internal
      : RoutingDnsProvider.custom;
}

class _RoutingChoiceChip extends StatelessWidget {
  const _RoutingChoiceChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ChoiceChip(
      avatar: Icon(
        icon,
        size: 17,
        color: selected ? Colors.white : colors.primary,
      ),
      label: Text(label),
      selected: selected,
      selectedColor: colors.primary,
      backgroundColor: colors.surface,
      labelStyle: TextStyle(
        color: selected ? Colors.white : colors.onSurface,
      ),
      side: BorderSide(
        color: selected ? AppTheme.primaryPressed : colors.outlineVariant,
        width: selected ? 2 : 1,
      ),
      onSelected: (_) => onSelected(),
    );
  }
}

class _RoutingAddMethodScreen extends StatelessWidget {
  const _RoutingAddMethodScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
            height: 1,
            thickness: 1,
            color: theme.dividerColor,
          ),
        ),
        centerTitle: false,
        leadingWidth: 48,
        titleSpacing: 0,
        title: Text(
          'Добавить шаблон',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            children: [
              Text(
                'Выберите способ создания шаблона',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              _RoutingChoiceCard(
                icon: Icons.content_paste_rounded,
                title: 'Вставить из буфера обмена',
                description: 'Импортировать скопированную ссылку или JSON.',
                onTap: () =>
                    Navigator.of(context).pop(_RoutingAddMethod.clipboard),
              ),
              const SizedBox(height: 8),
              _RoutingChoiceCard(
                icon: Icons.link_rounded,
                title: 'Ссылка на маршрутизацию',
                description: 'Импортировать готовый профиль по ссылке.',
                onTap: () => Navigator.of(context).pop(_RoutingAddMethod.link),
              ),
              const SizedBox(height: 8),
              _RoutingChoiceCard(
                icon: Icons.tune_rounded,
                title: 'Настроить вручную',
                description: 'Через форму или JSON-редактор для продвинутых.',
                onTap: () =>
                    Navigator.of(context).pop(_RoutingAddMethod.manual),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoutingManualMethodScreen extends StatelessWidget {
  const _RoutingManualMethodScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
            height: 1,
            thickness: 1,
            color: theme.dividerColor,
          ),
        ),
        centerTitle: false,
        leadingWidth: 48,
        titleSpacing: 0,
        title: Text(
          'Настроить вручную',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            children: [
              Text(
                'Выберите редактор',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              _RoutingChoiceCard(
                icon: Icons.tune_rounded,
                title: 'Через интерфейс',
                description:
                    'Добавлять домены, IP-адреса и порты отдельными правилами.',
                onTap: () =>
                    Navigator.of(context).pop(_RoutingManualMethod.interface),
              ),
              const SizedBox(height: 8),
              _RoutingChoiceCard(
                icon: Icons.code_rounded,
                title: 'JSON для продвинутых',
                description:
                    'Редактировать полный шаблон маршрутизации в формате Xray.',
                onTap: () =>
                    Navigator.of(context).pop(_RoutingManualMethod.json),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoutingChoiceCard extends StatelessWidget {
  const _RoutingChoiceCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: onTap,
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: colors.primary),
        ),
        title: Text(title,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(description),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

class _RoutingRuleTile extends StatelessWidget {
  const _RoutingRuleTile({
    required this.rule,
    required this.dragIndex,
    required this.onEdit,
    required this.onRemove,
  });

  final VpnRoutingRule rule;
  final int dragIndex;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      onTap: onEdit,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_targetIcon(rule.type),
              color: colors.onSurfaceVariant, size: 19),
          const SizedBox(width: 4),
          ReorderableDragStartListener(
            index: dragIndex,
            child: Tooltip(
              message: 'Перетащить',
              child: Icon(Icons.drag_indicator_rounded,
                  color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
      title: Text(
        rule.label ?? rule.displayValue,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: rule.label == null
          ? null
          : Text(
              rule.displayValue,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: IconButton(
        tooltip: 'Удалить правило',
        onPressed: onRemove,
        icon: const Icon(Icons.delete_outline_rounded),
      ),
    );
  }
}

IconData _targetIcon(RoutingTargetType type) => switch (type) {
      RoutingTargetType.domain => Icons.language_rounded,
      RoutingTargetType.ip => Icons.dns_rounded,
      RoutingTargetType.port => Icons.settings_ethernet_rounded,
    };

class _AddRoutingRuleDialog extends StatefulWidget {
  const _AddRoutingRuleDialog({required this.initialAction, this.rule});

  final RoutingAction initialAction;
  final VpnRoutingRule? rule;

  @override
  State<_AddRoutingRuleDialog> createState() => _AddRoutingRuleDialogState();
}

class _AddRoutingRuleDialogState extends State<_AddRoutingRuleDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _valueController = TextEditingController(text: widget.rule?.value);
  late RoutingTargetType _type = widget.rule?.type ?? RoutingTargetType.domain;
  late RoutingAction _action = widget.initialAction;

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final value = _valueController.text.trim();
    Navigator.of(context).pop(
      VpnRoutingRule(
        type: _type,
        value: _type == RoutingTargetType.domain ? value.toLowerCase() : value,
        action: _action,
        label: widget.rule?.label,
      ),
    );
  }

  String? _validateValue(String? rawValue) {
    final value = rawValue?.trim() ?? '';
    if (value.isEmpty) return 'Введите значение.';
    return switch (_type) {
      RoutingTargetType.domain => _isValidDomain(value)
          ? null
          : 'Введите домен без https:// и пути, например example.com.',
      RoutingTargetType.ip => _isValidIpOrNetwork(value)
          ? null
          : 'Введите IP-адрес или сеть в формате 192.168.1.0/24.',
      RoutingTargetType.port => _isValidPortOrRange(value)
          ? null
          : 'Введите порт от 1 до 65535 или диапазон, например 8000-8100.',
    };
  }

  bool _isValidDomain(String value) {
    if (value.length > 253) return false;
    final labels = value.split('.');
    if (labels.any((label) =>
        label.isEmpty ||
        label.length > 63 ||
        !RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')
            .hasMatch(label))) {
      return false;
    }
    return true;
  }

  bool _isValidIpOrNetwork(String value) {
    final parts = value.split('/');
    if (parts.length > 2) return false;
    final address = InternetAddress.tryParse(parts.first);
    if (address == null) return false;
    if (parts.length == 1) return true;
    final prefix = int.tryParse(parts.last);
    if (prefix == null) return false;
    final maximum = address.type == InternetAddressType.IPv4 ? 32 : 128;
    return prefix >= 0 && prefix <= maximum;
  }

  bool _isValidPortOrRange(String value) {
    final parts = value.split('-');
    if (parts.length > 2 || parts.any((part) => part.isEmpty)) return false;
    final ports = parts.map(int.tryParse).toList();
    if (ports.any((port) => port == null || port < 1 || port > 65535)) {
      return false;
    }
    return ports.length == 1 || ports.first! <= ports.last!;
  }

  @override
  Widget build(BuildContext context) {
    final (label, hint, helperText) = switch (_type) {
      RoutingTargetType.domain => (
          'Домен',
          'example.com',
          'Правило охватывает домен и его поддомены.',
        ),
      RoutingTargetType.ip => (
          'IP-адрес или сеть',
          '192.168.1.0/24',
          'Можно указать один адрес или сеть в формате CIDR.',
        ),
      RoutingTargetType.port => (
          'Порт или диапазон',
          '443 или 8000-8100',
          'Порт применяется к любому адресу, для TCP и UDP.',
        ),
    };
    return AlertDialog(
      title: Text(widget.rule == null ? 'Новое правило' : 'Изменить правило'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Что делать',
                  style: Theme.of(context).textTheme.labelLarge),
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final entry in const [
                  (RoutingAction.block, 'Блок', Icons.block_rounded),
                  (RoutingAction.proxy, 'Через VPN', Icons.shield_rounded),
                  (
                    RoutingAction.direct,
                    'Напрямую',
                    Icons.arrow_outward_rounded,
                  ),
                ])
                  _RoutingChoiceChip(
                    label: entry.$2,
                    icon: entry.$3,
                    selected: _action == entry.$1,
                    onSelected: () => setState(() => _action = entry.$1),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Тип адреса',
                  style: Theme.of(context).textTheme.labelLarge),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                for (final entry in const [
                  (
                    RoutingTargetType.domain,
                    'Сайт',
                    Icons.language_rounded,
                  ),
                  (RoutingTargetType.ip, 'IP', Icons.dns_rounded),
                  (
                    RoutingTargetType.port,
                    'Порт',
                    Icons.settings_ethernet_rounded,
                  ),
                ])
                  _RoutingChoiceChip(
                    label: entry.$2,
                    icon: entry.$3,
                    selected: _type == entry.$1,
                    onSelected: () => setState(() => _type = entry.$1),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _valueController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                helperText: helperText,
              ),
              validator: _validateValue,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена')),
        FilledButton(
            onPressed: _submit,
            child: Text(widget.rule == null ? 'Добавить' : 'Применить')),
      ],
    );
  }
}

class _EditStructuredRuleDialog extends StatefulWidget {
  const _EditStructuredRuleDialog({required this.rule});

  final VpnRoutingRule rule;

  @override
  State<_EditStructuredRuleDialog> createState() =>
      _EditStructuredRuleDialogState();
}

class _EditStructuredRuleDialogState extends State<_EditStructuredRuleDialog> {
  late final _domains =
      TextEditingController(text: widget.rule.domains.join('\n'));
  late final _ips = TextEditingController(text: widget.rule.ips.join('\n'));
  late final _ports = TextEditingController(text: widget.rule.ports.join('\n'));
  late final _networks =
      TextEditingController(text: widget.rule.networks.join(', '));
  late final _protocols =
      TextEditingController(text: widget.rule.protocols.join(', '));
  late RoutingAction _action = widget.rule.action;
  String? _error;

  @override
  void dispose() {
    _domains.dispose();
    _ips.dispose();
    _ports.dispose();
    _networks.dispose();
    _protocols.dispose();
    super.dispose();
  }

  List<String> _lines(TextEditingController controller) => controller.text
      .split(RegExp(r'[\r\n]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  List<String> _items(TextEditingController controller) => controller.text
      .split(RegExp(r'[,\r\n]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  void _submit() {
    final domains = _lines(_domains);
    final ips = _lines(_ips);
    final ports = _lines(_ports);
    final networks = _items(_networks);
    final protocols = _items(_protocols);
    final values = [...domains, ...ips, ...ports, ...networks, ...protocols];
    if (values.isEmpty) {
      setState(() => _error = 'Укажите хотя бы одно условие.');
      return;
    }
    if (networks.any((value) => value != 'tcp' && value != 'udp')) {
      setState(() => _error = 'Для сети укажите tcp, udp или оба значения.');
      return;
    }
    Navigator.of(context).pop(VpnRoutingRule(
      type: domains.isNotEmpty
          ? RoutingTargetType.domain
          : ips.isNotEmpty
              ? RoutingTargetType.ip
              : RoutingTargetType.port,
      value: values.join(' · '),
      action: _action,
      label: widget.rule.label,
      domains: domains,
      ips: ips,
      ports: ports,
      networks: networks,
      protocols: protocols,
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Изменить правило'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Маршрут',
                    style: Theme.of(context).textTheme.labelLarge),
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final entry in const [
                    (RoutingAction.block, 'Блок', Icons.block_rounded),
                    (RoutingAction.proxy, 'Через VPN', Icons.shield_rounded),
                    (
                      RoutingAction.direct,
                      'Напрямую',
                      Icons.arrow_outward_rounded,
                    ),
                  ])
                    _RoutingChoiceChip(
                      label: entry.$2,
                      icon: entry.$3,
                      selected: _action == entry.$1,
                      onSelected: () => setState(() => _action = entry.$1),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                  'Условия разных типов должны совпасть одновременно. Каждый сайт, IP или порт укажите с новой строки.',
                  style: Theme.of(context).textTheme.bodySmall),
              TextField(
                  controller: _domains,
                  minLines: 1,
                  maxLines: 4,
                  decoration:
                      const InputDecoration(labelText: 'Сайты и домены')),
              TextField(
                  controller: _ips,
                  minLines: 1,
                  maxLines: 4,
                  decoration:
                      const InputDecoration(labelText: 'IP-адреса и сети')),
              TextField(
                  controller: _ports,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Порты')),
              TextField(
                  controller: _networks,
                  decoration: const InputDecoration(
                      labelText: 'Сеть', hintText: 'tcp, udp')),
              TextField(
                  controller: _protocols,
                  decoration: const InputDecoration(
                      labelText: 'Протоколы', hintText: 'http, tls, quic')),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена')),
          FilledButton(onPressed: _submit, child: const Text('Применить')),
        ],
      );
}

class _RoutingLinkImportScreen extends StatefulWidget {
  const _RoutingLinkImportScreen();

  @override
  State<_RoutingLinkImportScreen> createState() =>
      _RoutingLinkImportScreenState();
}

class _RoutingLinkImportScreenState extends State<_RoutingLinkImportScreen> {
  final _controller = TextEditingController();
  bool _loadingFile = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openFile() async {
    setState(() => _loadingFile = true);
    try {
      final content = await _routingImportChannel
          .invokeMethod<String>('readRoutingTemplateFile');
      if (content != null && mounted) {
        setState(() => _controller.text = content);
      }
    } on PlatformException catch (error) {
      if (mounted && error.code != 'cancelled') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.code == 'qr_not_found'
                  ? 'В изображении не найден QR-код.'
                  : 'Не удалось открыть файл шаблона.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingFile = false);
    }
  }

  void _submit() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Вставьте ссылку или откройте файл.')),
      );
      return;
    }
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(
            height: 1,
            thickness: 1,
            color: theme.dividerColor,
          ),
        ),
        centerTitle: false,
        leadingWidth: 48,
        titleSpacing: 0,
        title: Text(
          'Ссылка на маршрутизацию',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
                  children: [
                    Text(
                      'Вставьте ссылку на готовый профиль маршрутизации. JSON-файл и QR-код можно открыть кнопкой ниже.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _controller,
                      minLines: 3,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: 'Ссылка или JSON',
                        hintText: 'https://…',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _loadingFile ? null : _openFile,
                      icon: _loadingFile
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.folder_open_rounded),
                      label: const Text('Открыть JSON или QR-код'),
                    ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loadingFile ? null : _submit,
                      child: const Text('Импортировать'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoutingTemplateJsonDialog extends StatefulWidget {
  const _RoutingTemplateJsonDialog({required this.initialJson});

  final String initialJson;

  @override
  State<_RoutingTemplateJsonDialog> createState() =>
      _RoutingTemplateJsonDialogState();
}

class _RoutingTemplateJsonDialogState
    extends State<_RoutingTemplateJsonDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialJson);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply() {
    try {
      final imported = RoutingTemplateImporter.parse(_controller.text);
      Navigator.of(context).pop(imported);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _copyJson() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('JSON скопирован в буфер обмена.')),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('JSON шаблона'),
        content: SizedBox(
          width: 620,
          height: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Расширенный режим для формата Xray. Оставляйте маршруты direct, proxy или block; неподдерживаемые поля будут пропущены.',
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: _controller,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _copyJson,
            child: const Text('Скопировать JSON'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(onPressed: _apply, child: const Text('Применить')),
        ],
      );
}
