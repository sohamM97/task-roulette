import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/database_helper.dart';
import '../providers/auth_provider.dart';
import '../services/sync_service.dart';
import '../utils/display_utils.dart' show isAllowedUrl;

/// Profile icon for the AppBar. Shows Google profile picture when signed in,
/// generic account icon when not. Includes sync status badge.
class ProfileIcon extends StatelessWidget {
  const ProfileIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        if (!auth.isConfigured) return const SizedBox.shrink();

        return IconButton(
          icon: _buildIcon(auth),
          onPressed: () => _showSheet(context, auth),
          tooltip: auth.isSignedIn ? 'Account' : 'Sign in',
        );
      },
    );
  }

  Widget _buildIcon(AuthProvider auth) {
    if (!auth.isSignedIn) {
      return const Icon(Icons.account_circle_outlined);
    }

    final photoUrl = auth.user?.photoUrl;
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty && isAllowedUrl(photoUrl);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 14,
          foregroundImage: hasPhoto ? NetworkImage(photoUrl) : null,
          onForegroundImageError: hasPhoto ? (error, stack) {} : null,
          child: const Icon(Icons.person, size: 18),
        ),
        Positioned(
          right: -2,
          bottom: -2,
          child: _syncBadge(auth.syncStatus),
        ),
      ],
    );
  }

  Widget _syncBadge(SyncStatus status) {
    switch (status) {
      case SyncStatus.syncing:
        return const SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        );
      case SyncStatus.synced:
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1),
          ),
        );
      case SyncStatus.error:
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Colors.red,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1),
          ),
        );
      case SyncStatus.idle:
        return const SizedBox.shrink();
    }
  }

  void _showSheet(BuildContext context, AuthProvider auth) {
    if (auth.isSignedIn) {
      _showSignedInSheet(context, auth);
    } else {
      _showSignedOutSheet(context, auth);
    }
  }

  void _showSignedOutSheet(BuildContext context, AuthProvider auth) {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_outlined, size: 48, color: colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Sync across devices',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in with Google to keep your tasks in sync across your phone and desktop.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final success = await auth.signIn();
                  if (!context.mounted) return;
                  if (success) {
                    final syncService = context.read<SyncService>();
                    await _handlePostSignIn(context, syncService);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Sign-in failed. Please try again.'),
                        showCloseIcon: true,
                        persist: false,
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.login),
                label: const Text('Sign in with Google'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// After sign-in, decide whether to show the migration choice dialog
  /// or proceed directly with initial migration.
  Future<void> _handlePostSignIn(BuildContext context, SyncService syncService) async {
    final needsMigration = await syncService.needsInitialMigration();
    if (!needsMigration) {
      syncService.startPeriodicPull();
      return;
    }

    final hasCloud = await syncService.hasCloudData();
    final hasLocal = (await DatabaseHelper().getRootTasks()).isNotEmpty;

    if (!hasCloud) {
      // No cloud data — just push local data up
      await syncService.initialMigration();
      syncService.startPeriodicPull();
      return;
    }

    if (!hasLocal) {
      // No local data — just pull cloud data down
      await syncService.replaceLocalWithCloud();
      syncService.startPeriodicPull();
      return;
    }

    // Both sides have data — ask the user what to do
    if (context.mounted) {
      _showMigrationChoiceDialog(context, syncService);
    }
  }

  void _showMigrationChoiceDialog(BuildContext context, SyncService syncService) {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_sync, size: 48, color: colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Cloud data found',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Your account already has tasks in the cloud. '
                'How would you like to handle the tasks on this device?',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              // Safe option — replace local with cloud (green)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await syncService.replaceLocalWithCloud();
                    syncService.startPeriodicPull();
                  },
                  icon: const Icon(Icons.cloud_download),
                  label: const Text('Use cloud data'),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Replaces tasks on this device with your cloud tasks.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // Neutral option — merge both
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await syncService.mergeBoth();
                    syncService.startPeriodicPull();
                  },
                  icon: const Icon(Icons.merge),
                  label: const Text('Merge both'),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Combines tasks from this device and the cloud.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // Dangerous option — replace cloud with local (amber)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange.shade800,
                    side: BorderSide(color: Colors.orange.shade800),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await syncService.replaceCloudWithLocal();
                    syncService.startPeriodicPull();
                  },
                  icon: const Icon(Icons.cloud_upload),
                  label: const Text('Use this device\'s data'),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Replaces cloud tasks with the tasks on this device. '
                'Use with caution — cloud data will be lost.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.orange.shade800,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _showSignedInSheet(BuildContext context, AuthProvider auth) {
    final colorScheme = Theme.of(context).colorScheme;
    final user = auth.user;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 32,
                foregroundImage: user?.photoUrl != null && user!.photoUrl!.isNotEmpty && isAllowedUrl(user.photoUrl!)
                    ? NetworkImage(user.photoUrl!)
                    : null,
                onForegroundImageError: user?.photoUrl != null ? (error, stack) {} : null,
                child: const Icon(Icons.person, size: 32),
              ),
              const SizedBox(height: 12),
              if (user?.displayName != null && user!.displayName!.isNotEmpty)
                Text(
                  user.displayName!,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              if (user?.email != null && user!.email!.isNotEmpty)
                Text(
                  user.email!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              const SizedBox(height: 16),
              _syncStatusRow(context, auth),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final syncService = context.read<SyncService>();
                      await syncService.syncNow();
                    },
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync now'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final syncService = context.read<SyncService>();
                      await syncService.handleSignOut();
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _syncStatusRow(BuildContext context, AuthProvider auth) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    String label;
    Color color;
    IconData icon;

    switch (auth.syncStatus) {
      case SyncStatus.idle:
        label = 'Not synced yet';
        color = colorScheme.onSurfaceVariant;
        icon = Icons.cloud_off;
      case SyncStatus.syncing:
        label = 'Syncing...';
        color = colorScheme.primary;
        icon = Icons.sync;
      case SyncStatus.synced:
        label = 'Synced';
        color = Colors.green;
        icon = Icons.cloud_done;
      case SyncStatus.error:
        label = auth.syncError ?? 'Sync error';
        color = colorScheme.error;
        icon = Icons.cloud_off;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: textTheme.bodySmall?.copyWith(color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
