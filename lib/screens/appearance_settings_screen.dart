import 'package:flutter/material.dart';

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({
    super.key,
    required this.themeMode,
  });

  final ThemeMode themeMode;

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
        title: Text(
          'Внешний вид',
          style: theme.textTheme.titleMedium
              ?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
            children: [
              Text(
                'Тема приложения',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _AppearanceOption(
                      mode: ThemeMode.system,
                      selected: themeMode == ThemeMode.system,
                      icon: Icons.brightness_auto_outlined,
                      title: 'Система',
                      subtitle: 'Как в настройках оформления устройства.',
                    ),
                    Divider(height: 1, color: theme.dividerColor),
                    _AppearanceOption(
                      mode: ThemeMode.light,
                      selected: themeMode == ThemeMode.light,
                      icon: Icons.light_mode_outlined,
                      title: 'Светлая',
                      subtitle: 'Всегда использовать светлую тему.',
                    ),
                    Divider(height: 1, color: theme.dividerColor),
                    _AppearanceOption(
                      mode: ThemeMode.dark,
                      selected: themeMode == ThemeMode.dark,
                      icon: Icons.dark_mode_outlined,
                      title: 'Тёмная',
                      subtitle: 'Всегда использовать тёмную тему.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppearanceOption extends StatelessWidget {
  const _AppearanceOption({
    required this.mode,
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final ThemeMode mode;
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      onTap: () => Navigator.of(context).pop(mode),
      leading: Icon(
        icon,
        color: selected ? colors.primary : colors.onSurfaceVariant,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Icon(
        selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off,
        color: selected ? colors.primary : colors.onSurfaceVariant,
      ),
    );
  }
}
