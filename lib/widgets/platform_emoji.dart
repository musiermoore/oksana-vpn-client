import 'package:flutter/material.dart';

/// Replaces Windows' regional-indicator text fallback with a small vector flag
/// and maps network signal emoji to Flutter's platform-independent icons.
class PlatformEmoji extends StatelessWidget {
  const PlatformEmoji({required this.value, required this.size, super.key});

  final String value;
  final double size;

  @override
  Widget build(BuildContext context) {
    final countryCode = countryCodeFromFlagEmoji(value);
    if (countryCode != null) {
      if (_FlagPainter.supports(countryCode)) {
        return CustomPaint(
          size: Size(size * 1.5, size),
          painter: _FlagPainter(countryCode),
        );
      }
      return Icon(Icons.flag_rounded, size: size, color: Colors.blueGrey);
    }

    final points = value.runes;
    final firstCodePoint = points.isEmpty ? null : points.first;
    if (firstCodePoint == 0x1f4f6) {
      return Icon(Icons.signal_cellular_alt_rounded, size: size);
    }
    if (firstCodePoint == 0x1f6dc) {
      return Icon(Icons.wifi_rounded, size: size);
    }
    return Text(value, style: TextStyle(fontSize: size));
  }
}

/// Displays text while replacing flags and network signal emoji with widgets.
class PlatformEmojiText extends StatelessWidget {
  const PlatformEmojiText({
    required this.value,
    required this.style,
    this.maxLines,
    this.overflow,
    super.key,
  });

  final String value;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    final plainText = StringBuffer();
    final emojiSize = style?.fontSize ?? 14;

    void flushPlainText() {
      if (plainText.isEmpty) return;
      spans.add(TextSpan(text: plainText.toString(), style: style));
      plainText.clear();
    }

    for (final grapheme in value.characters) {
      final firstCodePoint = grapheme.runes.first;
      final needsPlatformRendering =
          countryCodeFromFlagEmoji(grapheme) != null ||
              firstCodePoint == 0x1f4f6 ||
              firstCodePoint == 0x1f6dc;
      if (!needsPlatformRendering) {
        plainText.write(grapheme);
        continue;
      }

      flushPlainText();
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: PlatformEmoji(value: grapheme, size: emojiSize),
        ),
      );
    }
    flushPlainText();

    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

String? countryCodeFromFlagEmoji(String value) {
  final points = value.runes.toList(growable: false);
  if (points.length != 2 ||
      points.any((point) => point < 0x1f1e6 || point > 0x1f1ff)) {
    return null;
  }
  return String.fromCharCodes(points.map((point) => point - 0x1f1e6 + 0x41));
}

class _FlagPainter extends CustomPainter {
  const _FlagPainter(this.code);

  final String code;

  static bool supports(String code) => const {
        'AT',
        'BR',
        'CH',
        'DE',
        'DK',
        'EE',
        'ES',
        'FI',
        'FR',
        'IN',
        'IS',
        'IT',
        'JP',
        'NL',
        'NO',
        'PL',
        'RU',
        'SE',
        'TR',
        'UA',
        'US',
      }.contains(code);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final radius = Radius.circular(size.height * .1);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(bounds, radius));
    _fill(canvas, bounds, Colors.white);

    switch (code) {
      case 'FI':
        _cross(
          canvas,
          size,
          const Color(0xff003580),
          const Color(0xff003580),
          verticalCenter: .28,
          verticalThickness: .12,
          horizontalCenter: .45,
          horizontalThickness: .27,
        );
      case 'SE':
        _fill(canvas, bounds, const Color(0xff006aa7));
        _cross(
          canvas,
          size,
          const Color(0xfffecc00),
          const Color(0xfffecc00),
          verticalCenter: .31,
          verticalThickness: .125,
          horizontalCenter: .5,
          horizontalThickness: .2,
        );
      case 'DK':
        _fill(canvas, bounds, const Color(0xffc60c30));
        _cross(canvas, size, Colors.white, Colors.white);
      case 'NO':
        _fill(canvas, bounds, const Color(0xffba0c2f));
        _cross(canvas, size, Colors.white, Colors.white,
            verticalThickness: .22, horizontalThickness: .25);
        _cross(canvas, size, const Color(0xff00205b), const Color(0xff00205b),
            verticalThickness: .1, horizontalThickness: .12);
      case 'IS':
        _fill(canvas, bounds, const Color(0xff02529c));
        _cross(canvas, size, Colors.white, Colors.white,
            verticalThickness: .22, horizontalThickness: .25);
        _cross(canvas, size, const Color(0xffdc1e35), const Color(0xffdc1e35),
            verticalThickness: .1, horizontalThickness: .12);
      case 'DE':
        _horizontal(canvas, size,
            const [Colors.black, Color(0xffdd0000), Color(0xffffce00)]);
      case 'EE':
        _horizontal(
          canvas,
          size,
          const [Color(0xff4891d9), Colors.black, Colors.white],
        );
      case 'FR':
        _vertical(canvas, size,
            const [Color(0xff0055a4), Colors.white, Color(0xffef4135)]);
      case 'IT':
        _vertical(canvas, size,
            const [Color(0xff009246), Colors.white, Color(0xffce2b37)]);
      case 'NL':
        _horizontal(canvas, size,
            const [Color(0xffae1c28), Colors.white, Color(0xff21468b)]);
      case 'RU':
        _horizontal(canvas, size,
            const [Colors.white, Color(0xff0039a6), Color(0xffd52b1e)]);
      case 'UA':
        _horizontal(canvas, size, const [Color(0xff0057b7), Color(0xffffd700)]);
      case 'PL':
        _horizontal(canvas, size, const [Colors.white, Color(0xffdc143c)]);
      case 'AT':
        _horizontal(canvas, size,
            const [Color(0xffed2939), Colors.white, Color(0xffed2939)]);
      case 'ES':
        _horizontal(canvas, size,
            const [Color(0xffaa151b), Color(0xfff1bf00), Color(0xffaa151b)],
            weights: const [1, 2, 1]);
      case 'JP':
        _fill(canvas, bounds, Colors.white);
        canvas.drawCircle(Offset(size.width / 2, size.height / 2),
            size.height * .27, Paint()..color = const Color(0xffbc002d));
      case 'CH':
        _fill(canvas, bounds, const Color(0xffd52b1e));
        _centerCross(canvas, size, Colors.white);
      case 'US':
        _horizontal(canvas, size, const [
          Color(0xffb22234),
          Colors.white,
          Color(0xffb22234),
          Colors.white,
          Color(0xffb22234),
          Colors.white,
          Color(0xffb22234),
          Colors.white,
          Color(0xffb22234),
          Colors.white,
          Color(0xffb22234),
          Colors.white,
          Color(0xffb22234),
        ]);
        _rect(canvas, Rect.fromLTWH(0, 0, size.width * .43, size.height * .54),
            const Color(0xff3c3b6e));
      case 'BR':
        _fill(canvas, bounds, const Color(0xff009b3a));
        _diamond(canvas, size, const Color(0xffffdf00));
        canvas.drawCircle(Offset(size.width / 2, size.height / 2),
            size.height * .27, Paint()..color = const Color(0xff002776));
      case 'IN':
        _horizontal(canvas, size,
            const [Color(0xffff9933), Colors.white, Color(0xff138808)]);
        canvas.drawCircle(Offset(size.width / 2, size.height / 2),
            size.height * .15, Paint()..color = const Color(0xff000080));
      case 'TR':
        _fill(canvas, bounds, const Color(0xffe30a17));
        canvas.drawCircle(Offset(size.width * .42, size.height / 2),
            size.height * .28, Paint()..color = Colors.white);
        canvas.drawCircle(Offset(size.width * .49, size.height * .46),
            size.height * .23, Paint()..color = const Color(0xffe30a17));
    }
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, radius),
      Paint()
        ..color = Colors.black.withValues(alpha: .14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7,
    );
  }

  static void _fill(Canvas canvas, Rect rect, Color color) =>
      canvas.drawRect(rect, Paint()..color = color);

  static void _rect(Canvas canvas, Rect rect, Color color) =>
      canvas.drawRect(rect, Paint()..color = color);

  static void _horizontal(Canvas canvas, Size size, List<Color> colors,
      {List<double>? weights}) {
    final bandWeights = weights ?? List<double>.filled(colors.length, 1);
    final total = bandWeights.fold<double>(0, (sum, item) => sum + item);
    var top = 0.0;
    for (var i = 0; i < colors.length; i++) {
      final height = size.height * bandWeights[i] / total;
      _rect(canvas, Rect.fromLTWH(0, top, size.width, height), colors[i]);
      top += height;
    }
  }

  static void _vertical(Canvas canvas, Size size, List<Color> colors) {
    final width = size.width / colors.length;
    for (var i = 0; i < colors.length; i++) {
      _rect(canvas, Rect.fromLTWH(i * width, 0, width, size.height), colors[i]);
    }
  }

  static void _cross(
    Canvas canvas,
    Size size,
    Color vertical,
    Color horizontal, {
    double verticalCenter = .31,
    double verticalThickness = .14,
    double horizontalCenter = .5,
    double horizontalThickness = .2,
    double horizontalWidth = 1,
  }) {
    _rect(
      canvas,
      Rect.fromLTWH(
        size.width * verticalCenter - size.width * verticalThickness / 2,
        0,
        size.width * verticalThickness,
        size.height,
      ),
      vertical,
    );
    _rect(
      canvas,
      Rect.fromLTWH(
        0,
        size.height * horizontalCenter - size.height * horizontalThickness / 2,
        size.width * horizontalWidth,
        size.height * horizontalThickness,
      ),
      horizontal,
    );
  }

  static void _centerCross(Canvas canvas, Size size, Color color) {
    _rect(canvas,
        Rect.fromLTWH(size.width * .4, 0, size.width * .2, size.height), color);
    _rect(
        canvas,
        Rect.fromLTWH(0, size.height * .4, size.width, size.height * .2),
        color);
  }

  static void _diamond(Canvas canvas, Size size, Color color) {
    final path = Path()
      ..moveTo(size.width / 2, size.height * .08)
      ..lineTo(size.width * .92, size.height / 2)
      ..lineTo(size.width / 2, size.height * .92)
      ..lineTo(size.width * .08, size.height / 2)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _FlagPainter oldDelegate) =>
      oldDelegate.code != code;
}
