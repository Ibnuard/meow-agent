import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'router.dart';
import 'theme.dart';

/// Floating glass-dock bottom navigation.
///
/// Theme-aware: uses light surface in light mode, dark navy in dark mode.
/// The dock floats above the system gesture area with proper safe-area padding.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  static const _accent = Color(0xFF3B82F6);
  static const _accentLight = Color(0xFF60A5FA);
  static const _accentDark = Color(0xFF2563EB);

  static const _tabs = <_NavItem>[
    _NavItem(
      label: 'Home',
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
      route: AppRoutes.home,
    ),
    _NavItem(
      label: 'Activity',
      icon: Icons.bolt_outlined,
      activeIcon: Icons.bolt_rounded,
      route: AppRoutes.activity,
    ),
    _NavItem.featured(route: AppRoutes.defaultChat),
    _NavItem(
      label: 'Agent',
      icon: Icons.smart_toy_outlined,
      activeIcon: Icons.smart_toy_rounded,
      route: AppRoutes.agents,
    ),
    _NavItem(
      label: 'Settings',
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings_rounded,
      route: AppRoutes.settings,
    ),
  ];

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    final idx = _tabs.indexWhere(
      (t) => !t.isFeatured && location == t.route,
    );
    return idx;
  }

  @override
  Widget build(BuildContext context) {
    final extras = context.extras;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentIndex = _currentIndex(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    const dockHeight = 64.0;
    const featuredSize = 60.0;
    const featuredOverlap = 20.0;
    const stackHeight = dockHeight + featuredOverlap;

    final liftFromBottom = bottomInset > 0 ? bottomInset + 8 : 16.0;

    // Set system UI overlay style based on theme so virtual nav buttons
    // are visible in both light and dark modes.
    final overlayStyle = isDark
        ? const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness: Brightness.light,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
          )
        : const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarIconBrightness: Brightness.dark,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: true,
          );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        extendBody: true,
        body: child,
        bottomNavigationBar: Padding(
          padding: EdgeInsets.fromLTRB(18, 0, 18, liftFromBottom),
          child: SizedBox(
            height: stackHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _GlassDock(
                    height: dockHeight,
                    fill: extras.navBackground,
                    border: extras.navBorder,
                    isDark: isDark,
                    child: Row(
                      children: [
                        for (var i = 0; i < _tabs.length; i++)
                          Expanded(
                            child: _tabs[i].isFeatured
                                ? const SizedBox.shrink()
                                : _RegularTab(
                                    item: _tabs[i],
                                    selected: i == currentIndex,
                                    onTap: () => context.go(_tabs[i].route),
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _FeaturedChatButton(
                      size: featuredSize,
                      onTap: () => context.go(AppRoutes.defaultChat),
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

class _NavItem {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.route,
  }) : isFeatured = false;

  const _NavItem.featured({required this.route})
      : label = '',
        icon = Icons.chat_bubble_rounded,
        activeIcon = Icons.chat_bubble_rounded,
        isFeatured = true;

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final String route;
  final bool isFeatured;
}

class _GlassDock extends StatelessWidget {
  const _GlassDock({
    required this.height,
    required this.fill,
    required this.border,
    required this.isDark,
    required this.child,
  });

  final double height;
  final Color fill;
  final Color border;
  final bool isDark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: 0.08),
            blurRadius: isDark ? 28 : 20,
            spreadRadius: -8,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(40),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(40),
              border: Border.all(color: border, width: 1),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _RegularTab extends StatelessWidget {
  const _RegularTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final extras = context.extras;
    final iconColor = selected ? AppShell._accent : extras.navInactive;
    final labelColor = selected ? extras.navActive : extras.navInactive;

    return Material(
      color: Colors.transparent,
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        highlightColor: Colors.white.withValues(alpha: 0.04),
        splashColor: AppShell._accent.withValues(alpha: 0.08),
        child: SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                child: Icon(
                  selected ? item.activeIcon : item.icon,
                  key: ValueKey(selected),
                  size: 22,
                  color: iconColor,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                style: TextStyle(
                  color: labelColor,
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: 0.2,
                ),
                child: Text(item.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeaturedChatButton extends StatelessWidget {
  const _FeaturedChatButton({required this.size, required this.onTap});

  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [AppShell._accentLight, AppShell._accentDark],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: AppShell._accent.withValues(alpha: 0.45),
              blurRadius: 24,
              spreadRadius: -2,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.20),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            splashColor: Colors.white.withValues(alpha: 0.18),
            highlightColor: Colors.white.withValues(alpha: 0.06),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  top: 1,
                  left: 6,
                  right: 6,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.22),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
                const Icon(
                  Icons.chat_bubble_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
