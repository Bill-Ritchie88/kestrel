import 'package:flutter/widgets.dart';

import '../api/models.dart';

/// The sections of the passenger app: the sidebar on a laptop, the tab bar on
/// a phone.
enum Section { trip, assistant, flights, vouchers, help }

/// Which section is showing. It lives above the Navigator so that pages
/// pushed on top of the layout (confirm, rebooked) can send the passenger
/// back to a particular section.
class ShellController extends ChangeNotifier {
  Section section = Section.trip;

  /// A case opened from anywhere in the app; the Help section shows it first.
  HandoffCase? latestCase;

  /// True while a "talk to a person" request is on its way.
  bool requestingPerson = false;

  void go(Section s) {
    if (section == s) return;
    section = s;
    notifyListeners();
  }

  void showCase(HandoffCase c) {
    latestCase = c;
    section = Section.help;
    notifyListeners();
  }

  void setRequesting(bool v) {
    requestingPerson = v;
    notifyListeners();
  }

  /// A new passenger starts on their trip. Called while the layout is first
  /// built, so it does not notify.
  void resetForNewSession() {
    section = Section.trip;
    latestCase = null;
    requestingPerson = false;
  }
}

class ShellScope extends InheritedNotifier<ShellController> {
  const ShellScope({super.key, required ShellController shell, required super.child})
      : super(notifier: shell);

  static ShellController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellScope>()!.notifier!;

  static ShellController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ShellScope>()!.notifier!;
}
