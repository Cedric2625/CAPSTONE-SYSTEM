import 'package:flutter/material.dart';

/// Shared app-wide navigator key — used by main.dart's MaterialApp, and by
/// NotificationService to open the Alert Received screen when a
/// notification is tapped while that screen isn't already on top (it has no
/// BuildContext of its own to navigate with). A separate file rather than
/// living in main.dart avoids an import cycle: NotificationService is
/// imported by app_state.dart, which main.dart also imports.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
