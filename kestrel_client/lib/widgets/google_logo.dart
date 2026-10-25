import 'package:flutter/widgets.dart';

/// Google's "G" mark for the "Continue with Google" button, drawn from the
/// official vector paths (48 x 48 viewBox) and colours in Google's sign-in
/// branding guidelines, so it is crisp at any size and never recoloured.
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, this.size = 18});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox.square(dimension: size, child: CustomPaint(painter: _GooglePainter())),
      );
}

const _paths = [
  (Color(0xFFEA4335),
      'M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z'),
  (Color(0xFF4285F4),
      'M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z'),
  (Color(0xFFFBBC05),
      'M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z'),
  (Color(0xFF34A853),
      'M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z'),
];

final _parsed = [for (final (color, d) in _paths) (color, parseSvgPath(d))];

class _GooglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48, size.height / 48);
    for (final (color, path) in _parsed) {
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A minimal SVG path-data parser (M L H V C S Z, absolute and relative,
/// with repeated parameter sets) - enough for simple brand marks without
/// adding an SVG package.
Path parseSvgPath(String d) {
  final tokens = RegExp(r'[MmLlHhVvCcSsZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')
      .allMatches(d)
      .map((m) => m.group(0)!)
      .toList();
  final isCommand = RegExp(r'^[A-Za-z]$');
  final path = Path();
  var i = 0;
  var cmd = 'M';
  double x = 0, y = 0, startX = 0, startY = 0;
  Offset? lastControl; // second control point of the previous curve, for S/s
  double n() => double.parse(tokens[i++]);

  while (i < tokens.length) {
    if (isCommand.hasMatch(tokens[i])) {
      cmd = tokens[i++];
    } else if (cmd == 'Z' || cmd == 'z') {
      break; // numbers after a close: malformed, stop rather than loop
    }
    final rel = cmd == cmd.toLowerCase();
    final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
    switch (cmd.toUpperCase()) {
      case 'M':
        x = ox + n();
        y = oy + n();
        path.moveTo(x, y);
        startX = x;
        startY = y;
        cmd = rel ? 'l' : 'L'; // further pairs are implicit lines
        lastControl = null;
      case 'L':
        x = ox + n();
        y = oy + n();
        path.lineTo(x, y);
        lastControl = null;
      case 'H':
        x = ox + n();
        path.lineTo(x, y);
        lastControl = null;
      case 'V':
        y = oy + n();
        path.lineTo(x, y);
        lastControl = null;
      case 'C':
        final x1 = ox + n(), y1 = oy + n(), x2 = ox + n(), y2 = oy + n();
        x = ox + n();
        y = oy + n();
        path.cubicTo(x1, y1, x2, y2, x, y);
        lastControl = Offset(x2, y2);
      case 'S':
        final c1 = lastControl == null ? Offset(x, y) : Offset(2 * x - lastControl.dx, 2 * y - lastControl.dy);
        final x2 = ox + n(), y2 = oy + n();
        x = ox + n();
        y = oy + n();
        path.cubicTo(c1.dx, c1.dy, x2, y2, x, y);
        lastControl = Offset(x2, y2);
      case 'Z':
        path.close();
        x = startX;
        y = startY;
        lastControl = null;
    }
  }
  return path;
}
