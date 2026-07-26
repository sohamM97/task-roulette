import 'package:flutter/material.dart';

/// The two-line app bar title shared by the Starred and Today's 5 tabs — the
/// app name over the tab name, with an optional trailing badge beside the tab
/// name (Starred uses it for its count).
///
/// The app-name line steps down from 30px to 22px below [_compactWidth]. Both
/// tabs carry four action icons beside this title (five on Today's 5 in debug,
/// which adds the rollover icon), and once search was added the 30px line ran
/// out of room at phone width and ellipsised to "Task Rou…". Ellipsis is kept as
/// the last-resort fallback for extremely narrow windows, so the degradation is
/// still graceful rather than a RenderFlex overflow.
///
/// Lives in one place so the two tabs can't drift apart — they must look
/// identical apart from the tab name and badge.
class TabAppBarTitle extends StatelessWidget {
  const TabAppBarTitle({super.key, required this.subtitle, this.trailing});

  /// The tab name shown on the second line (e.g. 'Starred', "Today's 5").
  final String subtitle;

  /// Optional widget shown just after [subtitle] (e.g. the starred count badge).
  final Widget? trailing;

  /// Below this logical width the app name uses the compact size. Phone width
  /// plus headroom: at 360dp, four 48dp actions leave only ~150dp for the title,
  /// which the 30px line overruns.
  static const double _compactWidth = 420;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < _compactWidth;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Task Roulette',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Outfit',
            fontSize: compact ? 22 : 30,
            fontWeight: FontWeight.w400,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Flexible(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 16,
                  fontWeight: FontWeight.w300,
                  color: colorScheme.onSurfaceVariant,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 6),
              trailing!,
            ],
          ],
        ),
      ],
    );
  }
}
