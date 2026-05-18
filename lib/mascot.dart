import 'package:flutter/material.dart';

class ClaudeMascot extends StatefulWidget {
  final double size;
  final Color color;
  final bool animate;

  const ClaudeMascot({
    super.key,
    this.size = 48,
    this.color = const Color(0xFFE85A3D),
    this.animate = false,
  });

  @override
  State<ClaudeMascot> createState() => _ClaudeMascotState();
}

class _ClaudeMascotState extends State<ClaudeMascot>
    with TickerProviderStateMixin {
  late final AnimationController _bounce;

  @override
  void initState() {
    super.initState();
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.animate) _bounce.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant ClaudeMascot old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_bounce.isAnimating) {
      _bounce.repeat(reverse: true);
    } else if (!widget.animate && _bounce.isAnimating) {
      _bounce.stop();
      _bounce.value = 0;
    }
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) {
      return SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _MascotPainter(widget.color),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _bounce,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_bounce.value);
        final scale = 0.96 + 0.08 * t;
        final dy = -2.0 * t;
        return SizedBox.square(
          dimension: widget.size,
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(
              scale: scale,
              child: CustomPaint(
                size: Size.square(widget.size),
                painter: _MascotPainter(widget.color),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MascotPainter extends CustomPainter {
  final Color color;

  _MascotPainter(this.color);

  static const List<List<int>> _grid = [
    [0, 0, 1, 0, 0, 0, 0, 1, 0, 0],
    [0, 0, 1, 0, 0, 0, 0, 1, 0, 0],
    [0, 1, 1, 1, 1, 1, 1, 1, 1, 0],
    [1, 1, 2, 2, 1, 1, 2, 2, 1, 1],
    [1, 1, 2, 2, 1, 1, 2, 2, 1, 1],
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
    [0, 1, 1, 1, 1, 1, 1, 1, 1, 0],
    [0, 1, 0, 0, 0, 0, 0, 0, 1, 0],
    [0, 1, 0, 0, 0, 0, 0, 0, 1, 0],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final px = size.width / _grid[0].length;
    final paint = Paint()..color = color;
    for (int y = 0; y < _grid.length; y++) {
      for (int x = 0; x < _grid[y].length; x++) {
        if (_grid[y][x] == 1) {
          canvas.drawRect(
            Rect.fromLTWH(x * px, y * px, px + 0.5, px + 0.5),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_MascotPainter old) => old.color != color;
}
