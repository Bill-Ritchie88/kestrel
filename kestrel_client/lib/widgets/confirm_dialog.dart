import 'package:flutter/material.dart';

import '../theme.dart';

/// Asks before a destructive action (unlink, delete account data): what will
/// happen, Cancel, and the action in red. True only if the passenger chose
/// the action; dismissing the dialog is Cancel.
Future<bool> confirmDestructive(BuildContext context,
        {required String title, required String message, required String action}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: K.elevated,
        scrollable: true, // long text on a 375 px phone in large type
        icon: const Icon(Icons.warning_amber_rounded, color: K.glow, semanticLabel: 'Warning'),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(minimumSize: const Size(K.touch, K.touch)),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: K.crimson,
              foregroundColor: Colors.white,
              minimumSize: const Size(K.touch, K.touch),
            ),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
