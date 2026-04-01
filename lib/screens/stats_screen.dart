import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/xp_config.dart';
import '../providers/progression_provider.dart';
import '../providers/theme_provider.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => StatsScreenState();
}

class StatsScreenState extends State<StatsScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Show class picker on first visit if not chosen yet
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<ProgressionProvider>();
      if (!provider.classChosen) {
        _showClassPicker();
      }
    });
  }

  void refresh() {
    context.read<ProgressionProvider>().refresh();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Change class',
            onPressed: _showClassPicker,
          ),
          Consumer<ThemeProvider>(
            builder: (context, themeProvider, _) {
              return IconButton(
                icon: Icon(themeProvider.icon),
                onPressed: themeProvider.toggle,
                tooltip: 'Toggle theme',
              );
            },
          ),
        ],
      ),
      body: Consumer<ProgressionProvider>(
        builder: (context, provider, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _RankCard(provider: provider),
              const SizedBox(height: 16),
              _WeeklyActivityCard(provider: provider),
              const SizedBox(height: 16),
              _StreaksRow(provider: provider),
            ],
          );
        },
      ),
    );
  }

  void _showClassPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => const _ClassPickerSheet(),
    );
  }
}

// --- Rank Card ---

class _RankCard extends StatelessWidget {
  const _RankCard({required this.provider});
  final ProgressionProvider provider;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final nextMin = provider.nextMin;
    final isMaxRank = nextMin == null;

    return Card(
      color: colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Rank icon based on tier
            Icon(
              _rankIcon(provider.tierIndex),
              size: 48,
              color: colorScheme.onPrimaryContainer,
            ),
            const SizedBox(height: 8),
            Text(
              provider.rankTitle,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${provider.totalXp} XP',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            // Progress bar to next rank
            if (!isMaxRank) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: provider.rankProgress,
                  minHeight: 12,
                  backgroundColor: colorScheme.onPrimaryContainer.withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    colorScheme.onPrimaryContainer.withValues(alpha: 0.6),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${provider.totalXp - provider.currentMin} / ${nextMin - provider.currentMin} XP to next rank',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onPrimaryContainer.withValues(alpha: 0.6),
                ),
              ),
            ] else
              Text(
                'Max rank reached!',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
      ),
    );
  }

  IconData _rankIcon(int tierIndex) {
    const icons = [
      Icons.brightness_low,       // 0: Apprentice/Novice/Initiate
      Icons.shield_outlined,      // 1: Squire/Adventurer/Acolyte
      Icons.shield,               // 2: Knight/Pathfinder/Scribe
      Icons.flash_on,             // 3: Vanguard/Sentinel/Enchanter
      Icons.military_tech,        // 4: Champion/Champion/Sorcerer
      Icons.whatshot,             // 5: Warlord/Vanquisher/Archmage
      Icons.diamond_outlined,     // 6: Conqueror/Paragon/Sage
      Icons.auto_awesome,         // 7: Mythic
    ];
    return icons[tierIndex.clamp(0, icons.length - 1)];
  }
}

// --- Weekly Activity Card ---

class _WeeklyActivityCard extends StatelessWidget {
  const _WeeklyActivityCard({required this.provider});
  final ProgressionProvider provider;

  static const _dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final completions = provider.weeklyCompletions;
    final maxCount = completions.fold(0, (a, b) => a > b ? a : b);
    final today = DateTime.now().weekday - 1; // 0=Mon

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This Week',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Active ${provider.weekActiveDays} of 7 days',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            // Bar chart
            SizedBox(
              height: 120,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(7, (i) {
                  final count = completions[i];
                  final fraction = maxCount > 0 ? count / maxCount : 0.0;
                  final isToday = i == today;

                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (count > 0)
                            Text(
                              '$count',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                fontWeight: isToday ? FontWeight.bold : null,
                              ),
                            ),
                          const SizedBox(height: 4),
                          Flexible(
                            child: FractionallySizedBox(
                              heightFactor: fraction > 0 ? fraction.clamp(0.05, 1.0) : 0.05,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: isToday
                                      ? colorScheme.primary
                                      : count > 0
                                          ? colorScheme.primary.withValues(alpha: 0.5)
                                          : colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _dayLabels[i],
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontWeight: isToday ? FontWeight.bold : null,
                              color: isToday ? colorScheme.primary : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Streaks Row ---

class _StreaksRow extends StatelessWidget {
  const _StreaksRow({required this.provider});
  final ProgressionProvider provider;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StreakCard(
            icon: Icons.local_fire_department,
            iconColor: Colors.orange,
            label: 'Current Streak',
            value: provider.currentStreak,
            suffix: provider.currentStreak == 1 ? 'day' : 'days',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StreakCard(
            icon: Icons.emoji_events,
            iconColor: Colors.amber,
            label: 'Best Streak',
            value: provider.bestStreak,
            suffix: provider.bestStreak == 1 ? 'day' : 'days',
          ),
        ),
      ],
    );
  }
}

class _StreakCard extends StatelessWidget {
  const _StreakCard({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.suffix,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final int value;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 32, color: iconColor),
            const SizedBox(height: 8),
            Text(
              '$value',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              suffix,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Class Picker Bottom Sheet ---

class _ClassPickerSheet extends StatelessWidget {
  const _ClassPickerSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Choose Your Path',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This determines your rank titles as you earn XP. You can change it anytime.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _ClassOption(
              rankClass: RankClass.warrior,
              icon: Icons.shield,
              title: 'Warrior',
              description: 'Apprentice, Squire, Knight, Vanguard, Champion, Warlord, Conqueror',
            ),
            const SizedBox(height: 12),
            _ClassOption(
              rankClass: RankClass.adventurer,
              icon: Icons.explore,
              title: 'Adventurer',
              description: 'Novice, Adventurer, Pathfinder, Sentinel, Champion, Vanquisher, Paragon',
            ),
            const SizedBox(height: 12),
            _ClassOption(
              rankClass: RankClass.mage,
              icon: Icons.auto_awesome,
              title: 'Mage',
              description: 'Initiate, Acolyte, Scribe, Enchanter, Sorcerer, Archmage, Sage',
            ),
          ],
        ),
      ),
    );
  }
}

class _ClassOption extends StatelessWidget {
  const _ClassOption({
    required this.rankClass,
    required this.icon,
    required this.title,
    required this.description,
  });

  final RankClass rankClass;
  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ProgressionProvider>();
    final isSelected = provider.rankClass == rankClass;
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      color: isSelected ? colorScheme.primaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          provider.setRankClass(rankClass);
          Navigator.of(context).pop();
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                icon,
                size: 32,
                color: isSelected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isSelected ? colorScheme.onPrimaryContainer : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isSelected
                            ? colorScheme.onPrimaryContainer.withValues(alpha: 0.7)
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, color: colorScheme.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}
