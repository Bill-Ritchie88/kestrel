import 'package:flutter/widgets.dart';

import '../api/models.dart';
import '../auth/account_auth.dart';

/// The pages someone sees before signing in.
enum PublicPage { home, help, signIn, sessionExpired, linkBooking }

/// An account that signed in but has no booking linked yet, and the
/// bookings under its email address to offer.
class AccountLink {
  const AccountLink(this.identity, this.suggestions);
  final AccountIdentity identity;
  final List<LinkSuggestion> suggestions;
}

/// What the sign-in page shows: the account options (Google, email code),
/// the booking-reference form, or the staff-key form.
enum SignInMode { choose, guest, staff }

/// Sections of the Home page that links can jump to.
enum HomeAnchor { booking, howItWorks, rights, faq }

/// Which public page is showing. It lives above the Navigator, like the
/// passenger shell's controller, so a 401 anywhere in the app can open the
/// "session expired" page as it signs the passenger out.
class PublicController extends ChangeNotifier {
  PublicPage page = PublicPage.home;
  SignInMode mode = SignInMode.choose;

  /// Where Home should scroll to when it next opens.
  HomeAnchor? anchor;

  /// The account waiting on the Link booking page.
  AccountLink? pendingLink;

  /// A message for the sign-in page (e.g. why a Google sign-in didn't finish).
  String? notice;

  void showLinkBooking(AccountLink link) {
    pendingLink = link;
    page = PublicPage.linkBooking;
    notifyListeners();
  }

  String? takeNotice() {
    final n = notice;
    notice = null;
    return n;
  }

  void goHome([HomeAnchor? to]) {
    page = PublicPage.home;
    anchor = to;
    notifyListeners();
  }

  void goHelp() {
    page = PublicPage.help;
    notifyListeners();
  }

  void signIn([SignInMode m = SignInMode.choose]) {
    page = PublicPage.signIn;
    mode = m;
    notifyListeners();
  }

  void sessionExpired() {
    page = PublicPage.sessionExpired;
    notifyListeners();
  }

  HomeAnchor? takeAnchor() {
    final a = anchor;
    anchor = null;
    return a;
  }

  /// After signing in, signing out lands on Home. Called while the signed-in
  /// layout is first built, so it does not notify.
  void resetForSignedIn() {
    page = PublicPage.home;
    mode = SignInMode.choose;
    anchor = null;
    pendingLink = null;
    notice = null;
  }
}

class PublicScope extends InheritedNotifier<PublicController> {
  const PublicScope({super.key, required PublicController public, required super.child})
      : super(notifier: public);

  static PublicController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PublicScope>()!.notifier!;

  static PublicController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PublicScope>()!.notifier!;
}
