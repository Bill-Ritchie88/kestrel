import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/common.dart';
import 'staff_desk_screen.dart' deferred as staff;

/// The staff desk is a separate part of the web build (a deferred library):
/// passengers never download it. It is fetched when a member of staff signs
/// in, starting while their key is checked.
bool _loaded = false;
Future<void>? _loading;

Future<void> loadStaffDesk() {
  if (_loaded) return Future.value();
  return _loading ??= staff.loadLibrary().then((_) {
    _loaded = true;
    _loading = null;
  }, onError: (Object e) {
    _loading = null; // a later attempt tries again
    throw e;
  });
}

/// The staff desk, once its code has arrived.
class StaffDesk extends StatefulWidget {
  const StaffDesk({super.key});

  @override
  State<StaffDesk> createState() => _StaffDeskState();
}

class _StaffDeskState extends State<StaffDesk> {
  late Future<void> _ready = loadStaffDesk();

  @override
  Widget build(BuildContext context) {
    if (_loaded) return staff.StaffDeskScreen();
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done && !snapshot.hasError) {
          return staff.StaffDeskScreen();
        }
        return Scaffold(
          backgroundColor: K.base,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(K.s5),
              child: snapshot.hasError
                  ? ErrorNotice(
                      message: 'The disruption desk could not be loaded. Check your connection.',
                      onRetry: () => setState(() => _ready = loadStaffDesk()),
                    )
                  : const Loading('Opening the disruption desk'),
            ),
          ),
        );
      },
    );
  }
}
