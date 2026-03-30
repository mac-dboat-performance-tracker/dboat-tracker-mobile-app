import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' show Vector3;

class PaddleOrientation {
  // Rotation timeline (seconds) and quaternions [w,x,y,z]
  late final List<double> _t;
  late final List<double> _qw, _qx, _qy, _qz;

  // One-time alignment q_align = q_model0 * conj(q_imu0)
  _Q? _qAlign;
  double _yawOffsetDeg = 0.0;

  // Fixed view lock
  final double fixedXDeg;
  final double fixedYDeg;
  final double fixedZDeg;
  final bool yawOnly;

  PaddleOrientation({
    required List<double> tSec,
    required List<double> qw,
    required List<double> qx,
    required List<double> qy,
    required List<double> qz,
    this.fixedXDeg = 0.0,
    this.fixedYDeg = 0.0,
    this.fixedZDeg = 0.0,
    this.yawOnly = true,
  }) {
    // Normalize/sort timeline
    final n = tSec.length;
    final idxs = List<int>.generate(n, (i) => i)
      ..sort((a, b) => tSec[a].compareTo(tSec[b]));
    _t = [for (final i in idxs) tSec[i]];
    _qw = [for (final i in idxs) qw[i]];
    _qx = [for (final i in idxs) qx[i]];
    _qy = [for (final i in idxs) qy[i]];
    _qz = [for (final i in idxs) qz[i]];
    // Normalize and continuity-correct
    for (var i = 0; i < n; i++) {
      final nrm = math.sqrt(
        _qw[i] * _qw[i] + _qx[i] * _qx[i] + _qy[i] * _qy[i] + _qz[i] * _qz[i],
      );
      if (nrm > 1e-9) {
        _qw[i] /= nrm;
        _qx[i] /= nrm;
        _qy[i] /= nrm;
        _qz[i] /= nrm;
      } else {
        _qw[i] = 1;
        _qx[i] = _qy[i] = _qz[i] = 0;
      }
      if (i > 0) {
        final dot =
            _qw[i - 1] * _qw[i] +
            _qx[i - 1] * _qx[i] +
            _qy[i - 1] * _qy[i] +
            _qz[i - 1] * _qz[i];
        if (dot < 0) {
          _qw[i] = -_qw[i];
          _qx[i] = -_qx[i];
          _qy[i] = -_qy[i];
          _qz[i] = -_qz[i];
        }
      }
    }
    // Alignment from first sample; base neutral only uses X tilt; view lock supplied via fixed*Deg
    _initAlignment();
  }

  void _initAlignment() {
    if (_t.isEmpty) return;
    var w = _qw[0], x = _qx[0], y = _qy[0], z = _qz[0];
    final nrm = math.sqrt(w * w + x * x + y * y + z * z);
    if (nrm > 1e-9) {
      w /= nrm;
      x /= nrm;
      y /= nrm;
      z /= nrm;
    } else {
      w = 1;
      x = y = z = 0;
    }
    final qImu0 = _Q(w, x, y, z);
    final qModel0 = _qFromEulerDeg(90, 0, 0); // blade vertical by X tilt
    _qAlign = _qMul(qModel0, _qConj(qImu0));
    final qDisp0 = _qMul(_qAlign!, qImu0);
    _yawOffsetDeg = -_yawFromQuatDeg(qDisp0);
  }

  // Return Euler (deg) at time tSec. Uses slerp + yaw-only if configured, plus fixed view lock.
  Vector3 eulerAt(double tSec) {
    if (_t.isEmpty) return Vector3(fixedXDeg, fixedYDeg, fixedZDeg);
    var j = _lowerBound(_t, tSec);
    if (j > 0 && j < _t.length) {
      final prev = (tSec - _t[j - 1]).abs(), next = (_t[j] - tSec).abs();
      if (prev <= next) j = j - 1;
    } else if (j >= _t.length)
      j = _t.length - 1;
    final jn = (j + 1 < _t.length) ? j + 1 : j;

    var w = _qw[j], x = _qx[j], y = _qy[j], z = _qz[j];
    var wn = _qw[jn], xn = _qx[jn], yn = _qy[jn], zn = _qz[jn];
    final nrm = math.sqrt(w * w + x * x + y * y + z * z);
    if (nrm > 1e-9) {
      w /= nrm;
      x /= nrm;
      y /= nrm;
      z /= nrm;
    } else {
      w = 1;
      x = y = z = 0;
    }
    final nrmn = math.sqrt(wn * wn + xn * xn + yn * yn + zn * zn);
    if (nrmn > 1e-9) {
      wn /= nrmn;
      xn /= nrmn;
      yn /= nrmn;
      zn /= nrmn;
    } else {
      wn = 1;
      xn = yn = zn = 0;
    }
    final qj = _Q(w, x, y, z), qn = _Q(wn, xn, yn, zn);

    double tInterp = 0.0;
    if (jn != j) {
      final dt = _t[jn] - _t[j];
      tInterp = dt > 1e-9 ? ((tSec - _t[j]) / dt).clamp(0.0, 1.0) : 0.0;
    }
    final qImu = _qSlerp(qj, qn, tInterp);
    final qDisp = (_qAlign != null) ? _qMul(_qAlign!, qImu) : qImu;

    if (yawOnly) {
      final yawDeg = _yawFromQuatDeg(qDisp) + _yawOffsetDeg;
      return Vector3(fixedXDeg, fixedYDeg, yawDeg + fixedZDeg);
    } else {
      final e = _quatToEulerZYXDeg(qDisp.w, qDisp.x, qDisp.y, qDisp.z);
      return Vector3(e.x + fixedXDeg, e.y + fixedYDeg, e.z + fixedZDeg);
    }
  }
}

// Math helpers
class _Q {
  final double w, x, y, z;
  const _Q(this.w, this.x, this.y, this.z);
}

_Q _qConj(_Q q) => _Q(q.w, -q.x, -q.y, -q.z);
_Q _qMul(_Q a, _Q b) => _Q(
  a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
  a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
  a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
  a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
);
_Q _qFromEulerDeg(double rx, double ry, double rz) {
  final cx = math.cos(rx * math.pi / 360), sx = math.sin(rx * math.pi / 360);
  final cy = math.cos(ry * math.pi / 360), sy = math.sin(ry * math.pi / 360);
  final cz = math.cos(rz * math.pi / 360), sz = math.sin(rz * math.pi / 360);
  final qw = cx * cy * cz - sx * sy * sz;
  final qx = sx * cy * cz + cx * sy * sz;
  final qy = cx * sy * cz - sx * cy * sz;
  final qz = cx * cy * sz + sx * sy * cz;
  final n = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz);
  return n > 1e-9 ? _Q(qw / n, qx / n, qy / n, qz / n) : const _Q(1, 0, 0, 0);
}

_Q _qSlerp(_Q a, _Q b, double t) {
  double cosHalfTheta = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z;
  if (cosHalfTheta < 0.0) {
    b = _Q(-b.w, -b.x, -b.y, -b.z);
    cosHalfTheta = -cosHalfTheta;
  }
  if (cosHalfTheta > 0.9995) {
    final w = a.w + t * (b.w - a.w);
    final x = a.x + t * (b.x - a.x);
    final y = a.y + t * (b.y - a.y);
    final z = a.z + t * (b.z - a.z);
    final n = math.sqrt(w * w + x * x + y * y + z * z);
    return n > 1e-9 ? _Q(w / n, x / n, y / n, z / n) : const _Q(1, 0, 0, 0);
  }
  final halfTheta = math.acos(cosHalfTheta);
  final sinHalfTheta = math.sqrt(1.0 - cosHalfTheta * cosHalfTheta);
  final ratioA = math.sin((1 - t) * halfTheta) / sinHalfTheta;
  final ratioB = math.sin(t * halfTheta) / sinHalfTheta;
  final w = a.w * ratioA + b.w * ratioB;
  final x = a.x * ratioA + b.x * ratioB;
  final y = a.y * ratioA + b.y * ratioB;
  final z = a.z * ratioA + b.z * ratioB;
  return _Q(w, x, y, z);
}

double _yawFromQuatDeg(_Q q) {
  final siny_cosp = 2.0 * (q.w * q.z + q.x * q.y);
  final cosy_cosp = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
  final yaw = math.atan2(siny_cosp, cosy_cosp);
  return yaw * 180.0 / math.pi;
}

Vector3 _quatToEulerZYXDeg(double w, double x, double y, double z) {
  final siny_cosp = 2.0 * (w * z + x * y);
  final cosy_cosp = 1.0 - 2.0 * (y * y + z * z);
  final yaw = math.atan2(siny_cosp, cosy_cosp);
  var sinp = 2.0 * (w * y - z * x);
  sinp = sinp.clamp(-1.0, 1.0);
  final pitch = math.asin(sinp);
  final sinr_cosp = 2.0 * (w * x + y * z);
  final cosr_cosp = 1.0 - 2.0 * (x * x + y * y);
  final roll = math.atan2(sinr_cosp, cosr_cosp);
  return Vector3(
    roll * 180.0 / math.pi,
    pitch * 180.0 / math.pi,
    yaw * 180.0 / math.pi,
  );
}

// Binary search: first index i where a[i] >= x. Returns a.length if all < x.
int _lowerBound(List<double> a, double x) {
  var lo = 0;
  var hi = a.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (a[mid] < x) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}
