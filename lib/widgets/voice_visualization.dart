import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../controllers/voice_controller.dart';
import '../theme/app_tokens.dart';

/// Visual motion only: this observes VoicePhase and never owns audio or requests.
/// Speaking rhythm is state-driven, not a measured audio amplitude.
class AuroraMotion extends ChangeNotifier {
  AuroraMotion(VoicePhase phase)
    : _target = phase,
      _activation =
          phase == VoicePhase.initializing || phase == VoicePhase.listening
              ? 0
              : 1;
  VoicePhase _target;
  double angle = 0;
  double energy = .18;
  double speed = 0;
  double _activation;
  VoicePhase get target => _target;
  bool get settling => _target != VoicePhase.speaking;
  bool get settled =>
      settling &&
      _activation >= 1 &&
      speed < .001 &&
      (energy - _energy).abs() < .001;
  double get _energy => switch (_target) {
    VoicePhase.listening => .85,
    VoicePhase.speaking => .65,
    VoicePhase.processing => .40,
    VoicePhase.initializing || VoicePhase.transcribing => .30,
    VoicePhase.idle => .18,
    VoicePhase.paused || VoicePhase.error => .08,
  };
  // Sustained motion follows the existing native TTS start/completion state.
  // Listening/Thinking get a one-shot activation, then remain settled.
  double get _speed => _target == VoicePhase.speaking ? .95 : 0;
  void targetPhase(VoicePhase phase) {
    final start =
        phase == VoicePhase.initializing || phase == VoicePhase.listening;
    if (start &&
        (_target == VoicePhase.idle ||
            _target == VoicePhase.paused ||
            _target == VoicePhase.error)) {
      _activation = 0;
    } else if (phase == VoicePhase.speaking ||
        phase == VoicePhase.paused ||
        phase == VoicePhase.error ||
        phase == VoicePhase.idle) {
      _activation = 1;
    }
    _target = phase;
  }

  /// Integrate time instead of restarting a repeating controller on state change.
  /// A delayed frame cannot fast-forward the orb through a visible jump.
  void advance(double seconds) {
    final dt = seconds.clamp(0.0, .05);
    final blend = 1 - math.exp(-dt * 6);
    final speedBlend = 1 - math.exp(-dt * (settling ? 12 : 6));
    speed += (_speed - speed) * speedBlend;
    energy += (_energy - energy) * blend;
    // One 800 ms eased activation on Start Talking. It finishes once and does
    // not turn Listening/Thinking into an always-running animation.
    final previous = _activation;
    _activation = (_activation + dt / .8).clamp(0.0, 1.0);
    double ease(double p) => p * p * (3 - 2 * p);
    angle += speed * dt + .65 * (ease(_activation) - ease(previous));
    notifyListeners();
  }
}

class VoiceVisualization extends StatefulWidget {
  final VoicePhase phase;
  final double size;
  const VoiceVisualization({super.key, required this.phase, this.size = 280});
  @override
  State<VoiceVisualization> createState() => _VoiceVisualizationState();
}

class _VoiceVisualizationState extends State<VoiceVisualization>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AuroraMotion _motion = AuroraMotion(widget.phase);
  late final Ticker _ticker = createTicker(_tick);
  Duration? _previous;
  bool _visible = true;
  bool _reduced = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  void _tick(Duration elapsed) {
    final previous = _previous;
    _previous = elapsed;
    if (previous != null) {
      _motion.advance((elapsed - previous).inMicroseconds / 1000000);
    }
    if (_motion.settled) _sync();
  }

  void _sync() {
    final run = _visible && _foreground && !_reduced && !_motion.settled;
    if (run && !_ticker.isActive) {
      _previous = null;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
      _previous = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.of(context);
    _reduced = AppMotion.reduced(context);
    _sync();
  }

  @override
  void didUpdateWidget(covariant VoiceVisualization oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) {
      _motion.targetPhase(widget.phase);
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(painter: AuroraOrbPainter(_motion)),
      ),
    ),
  );
}

/// A small, procedurally shaded surface projected onto Flutter's Canvas.
/// This is a 2.5D illustration, not a 3D renderer: no textures, lighting engine,
/// blur or saveLayer. Geometry, normals and soft studio shading are cached; only projection
/// changes per frame. The surface has real folds rather than painted stripes.
class AuroraOrbPainter extends CustomPainter {
  final AuroraMotion motion;
  static final _surface = _AuroraSurface();
  final _positions = Float32List(_surface.points.length * 2);
  final _depths = Float32List(_surface.points.length);
  final _normalDepths = Float32List(_surface.points.length);
  // Counting-sort depth bins are subpixel at the largest displayed orb size.
  // They avoid a comparison sort and per-face allocations on every frame.
  static const _binCount = 4096;
  final _faceBins = Int32List(_surface.faces.length);
  final _binOffsets = Int32List(_binCount);
  final _rowCos = Float64List(_AuroraSurface.rows + 1);
  final _rowSin = Float64List(_AuroraSurface.rows + 1);
  final _indices = Uint16List(_surface.faces.length * 3);
  AuroraOrbPainter(this.motion) : super(repaint: motion);

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final t = motion.angle;
    final e = motion.energy;
    final center = Offset(size.width / 2, size.height * .47);
    final r =
        side *
        .38 *
        (.985 + e * .025) *
        (1 + math.sin(t * 2) * (.006 + e * .032));
    final halo = Rect.fromCircle(center: center, radius: side * .5);
    canvas.drawOval(
      halo,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFC3ACF2).withValues(alpha: .48 + e * .1),
            const Color(0xFFB8BEF1).withValues(alpha: .27),
            const Color(0x00B8BEF1),
          ],
          stops: const [0, .60, 1],
        ).createShader(halo),
    );
    canvas.save();
    canvas.translate(center.dx, side * .91);
    canvas.scale(r * .83, side * .035);
    canvas.drawCircle(
      Offset.zero,
      1,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x306D57AD), Color(0x006D57AD)],
        ).createShader(const Rect.fromLTRB(-1, -1, 1, 1)),
    );
    canvas.restore();

    // Slow bounded turns let the viewer see the folded surface while avoiding
    // a continuously spinning loader. State changes preserve the same phase.
    final yaw = -.28 + math.sin(t * .65) * .45;
    final pitch = -.13 + math.sin(t * 1.3) * .05;
    const tilt = -.30;
    for (var row = 0; row <= _AuroraSurface.rows; row++) {
      final flow =
          math.sin(t + row / _AuroraSurface.rows * math.pi * 2) *
          (.025 + e * .12);
      _rowCos[row] = math.cos(yaw + flow);
      _rowSin[row] = math.sin(yaw + flow);
    }
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final ct = math.cos(tilt), st = math.sin(tilt);
    for (var i = 0; i < _surface.points.length; i++) {
      final v = _surface.points[i];
      final row = i ~/ (_AuroraSurface.columns + 1);
      final cy = _rowCos[row], sy = _rowSin[row];
      final x = v.x * cy + v.z * sy;
      final z = -v.x * sy + v.z * cy;
      final y = v.y * cp - z * sp;
      final depth = v.y * sp + z * cp;
      final perspective = r / (1 - depth * .10);
      _positions[i * 2] = center.dx + (x * ct - y * st) * perspective;
      _positions[i * 2 + 1] = center.dy + (x * st + y * ct) * perspective;
      _depths[i] = depth;
      final n = _surface.normals[i];
      _normalDepths[i] = n.y * sp + (-n.x * sy + n.z * cy) * cp;
    }
    // Reuse typed projection buffers. Surface color is softly prelit once,
    // like a studio illustration, rather than allocating colors per frame.
    _binOffsets.fillRange(0, _binCount, 0);
    for (var i = 0; i < _surface.faces.length; i++) {
      final face = _surface.faces[i];
      if (_normalDepths[face.$1] +
              _normalDepths[face.$2] +
              _normalDepths[face.$3] <
          -.12) {
        _faceBins[i] = -1;
        continue;
      }
      final depth = _depths[face.$1] + _depths[face.$2] + _depths[face.$3];
      final bin = ((depth + 3.3) * (_binCount - 1) / 6.6).toInt().clamp(
        0,
        _binCount - 1,
      );
      _faceBins[i] = bin;
      _binOffsets[bin] += 3;
    }
    var index = 0;
    for (var bin = 0; bin < _binCount; bin++) {
      final count = _binOffsets[bin];
      _binOffsets[bin] = index;
      index += count;
    }
    for (var i = 0; i < _surface.faces.length; i++) {
      final bin = _faceBins[i];
      if (bin < 0) {
        continue;
      }
      final face = _surface.faces[i];
      final offset = _binOffsets[bin];
      _indices[offset] = face.$1;
      _indices[offset + 1] = face.$2;
      _indices[offset + 2] = face.$3;
      _binOffsets[bin] += 3;
    }
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      _positions,
      colors: _surface.colors,
      indices: Uint16List.sublistView(_indices, 0, index),
    );
    canvas.drawVertices(vertices, BlendMode.src, Paint());
    vertices.dispose();
  }

  @override
  bool shouldRepaint(AuroraOrbPainter oldDelegate) =>
      oldDelegate.motion != motion;
}

class _Vector {
  final double x, y, z;
  const _Vector(this.x, this.y, this.z);
  _Vector operator -(_Vector v) => _Vector(x - v.x, y - v.y, z - v.z);
  _Vector cross(_Vector v) =>
      _Vector(y * v.z - z * v.y, z * v.x - x * v.z, x * v.y - y * v.x);
  double dot(_Vector v) => x * v.x + y * v.y + z * v.z;
  _Vector get normalized {
    final length = math.sqrt(dot(this));
    return _Vector(x / length, y / length, z / length);
  }
}

class _AuroraSurface {
  static const rows = 80, columns = 80;
  final _waves = <double>[];
  final points = <_Vector>[];
  final normals = <_Vector>[];
  final faces = <(int, int, int)>[];
  late final Int32List colors;
  _AuroraSurface() {
    for (var row = 0; row <= rows; row++) {
      final theta = (row / rows * math.pi).clamp(.001, math.pi - .001);
      for (var column = 0; column <= columns; column++) {
        final phi = column / columns * math.pi * 2;
        points.add(_point(theta, phi));
        _waves.add(10 * theta + 3 * phi);
        final vertical =
            _point(theta + .0005, phi) - _point(theta - .0005, phi);
        final horizontal =
            _point(theta, phi + .0005) - _point(theta, phi - .0005);
        normals.add(vertical.cross(horizontal).normalized);
        if (row < rows && column < columns) {
          final a = row * (columns + 1) + column;
          final b = a + columns + 1;
          faces.add((a, b, a + 1));
          faces.add((a + 1, b, b + 1));
        }
      }
    }
    colors = Int32List.fromList(
      List.generate(
        points.length,
        (i) => _shade(normals[i], points[i], _waves[i]).toARGB32(),
      ),
    );
  }
  // Prelit vertex colors provide soft pearlescent shading at low runtime cost.
  // The moving surface carries this studio lighting; this is not physical PBR.
  Color _shade(_Vector n, _Vector p, double wave) {
    final normal =
        _Vector(n.x * .96 - n.z * .28, n.y, n.x * .28 + n.z * .96).normalized;
    final ridge = .5 + .5 * math.cos(wave);
    final pearl = (.5 + .5 * math.sin(normal.x * 1.8 + p.y * 1.4)).clamp(
      0.0,
      1.0,
    );
    final body =
        Color.lerp(const Color(0xFFAD9DDD), const Color(0xFFE0ACD3), pearl)!;
    // Thin mint reflections follow the physical crests. Broad lavender/pink
    // faces and gently occluded recesses reveal distinct overlapping folds.
    final edge = math.pow(((ridge - .55) / .45).clamp(0.0, 1.0), .7).toDouble();
    final base = Color.lerp(body, const Color(0xFFB1EBE3), edge * .90)!;
    final diffuse = normal.dot(const _Vector(-.45, -.55, .705)).clamp(0.0, 1.0);
    final specular =
        math
            .pow(
              normal.dot(const _Vector(-.243, -.297, .923)).clamp(0.0, 1.0),
              10,
            )
            .toDouble();
    final rim = math.pow(1 - normal.z.clamp(0.0, 1.0), 3).toDouble();
    final valley = math.pow(1 - ridge, 4).toDouble();
    final illumination = .77 + diffuse * .25 - valley * .12;
    double channel(double value, double sheen) =>
        (value * illumination + specular * .18 + rim * sheen).clamp(0.0, 1.0);
    return Color.from(
      alpha: 1,
      red: channel(base.r, .10),
      green: channel(base.g, .15),
      blue: channel(base.b, .17),
    );
  }

  _Vector _point(double theta, double phi) {
    final wave = 10 * theta + 3 * phi;
    final radius = math.sin(theta) * (.89 + .11 * math.cos(wave));
    final twist = phi + .22 * math.cos(theta);
    return _Vector(
      radius * math.cos(twist),
      -math.cos(theta) * .94,
      radius * math.sin(twist),
    );
  }
}
