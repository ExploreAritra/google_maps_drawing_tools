// File: lib/src/drawing_controller.dart

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_drawing_tools/src/models/drawable_rectangle.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:collection/collection.dart';
import 'models/drawable_circle.dart';
import 'models/drawable_polygon.dart';
import 'models/drawable_polyline.dart';
import 'models/drawable_shape_bundle.dart';

enum DrawMode { none, polygon, polyline, circle, rectangle, freehand }

typedef OnPolygonDrawn = void Function(DrawablePolygon polygon);

class DrawingController extends ChangeNotifier {
  DrawingController({
    this.onPolygonDrawn,
    this.onPolygonSelected,
    this.onPolygonUpdated,
    this.onPolygonDeleted,
    BitmapDescriptor? firstPolygonMarker,
    BitmapDescriptor? customPolygonMarker,
    BitmapDescriptor? midpointPolygonMarker,
    BitmapDescriptor? circleCenterMarker,
    BitmapDescriptor? circleRadiusHandle,
    BitmapDescriptor? rectangleStartMarker,
  }) {
    // Set default custom icon if none is passed
    firstPolygonMarkerIcon = firstPolygonMarker ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
    customPolygonMarkerIcon = customPolygonMarker ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue);
    midpointPolygonMarkerIcon = midpointPolygonMarker ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueYellow);
    circleCenterMarkerIcon = circleCenterMarker ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
    circleRadiusHandleIcon = circleRadiusHandle ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    rectangleStartMarkerIcon = rectangleStartMarker ??
        BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
  }

  /// Polygon Drawing Logic
  late BitmapDescriptor customPolygonMarkerIcon;
  late BitmapDescriptor firstPolygonMarkerIcon;
  late BitmapDescriptor midpointPolygonMarkerIcon;
  DrawMode _currentMode = DrawMode.none;
  final List<DrawablePolygon> _polygons = [];
  final List<DrawablePolyline> _polylines = [];
  DrawablePolyline? _activePolyline;
  DrawablePolygon? _activePolygon;
  DrawablePolygon? _selectedPolygon;
  GoogleMapController? googleMapController;

  /// Callback for when a polygon is drawn
  void Function(List<DrawablePolygon> allPolygons)? onPolygonDrawn;

  /// Called when a polygon is selected
  void Function(DrawablePolygon selected)? onPolygonSelected;

  /// Called when a polygon is updated (points or color)
  void Function(DrawablePolygon updated)? onPolygonUpdated;

  /// Called when a polygon is deleted
  void Function(String deletedPolygonId)? onPolygonDeleted;

  double currentZoom = 0;

  DrawMode get currentMode => _currentMode;
  List<DrawablePolygon> get polygons => List.unmodifiable(_polygons);
  DrawablePolygon? get selectedPolygon => _selectedPolygon;

  String? get activePolygonId => _activePolygon?.id;
  // Update this on map tap or move
  LatLng? currentCursorPosition;

  Color _currentDrawingColor = Colors.red;

  Color get currentDrawingColor => _currentDrawingColor;

  // Function to set a custom marker icon
  void setFirstPolygonCustomMarkerIcon(BitmapDescriptor icon) {
    firstPolygonMarkerIcon = icon;
    notifyListeners(); // This will trigger the UI update to use the new icon
  }

  void setMidpointPolygonCustomMarkerIcon(BitmapDescriptor icon) {
    midpointPolygonMarkerIcon = icon;
    notifyListeners(); // This will trigger the UI update to use the new icon
  }

  void setPolygonCustomMarkerIcon(BitmapDescriptor icon) {
    customPolygonMarkerIcon = icon;
    notifyListeners(); // This will trigger the UI update to use the new icon
  }

  void setColor(Color color) {
    _currentDrawingColor = color;
    notifyListeners();
  }

  void updateColor(String id, Color newColor) {
    if (currentMode == DrawMode.polygon) {
      final index = _polygons.indexWhere((p) => p.id == id);
      if (index == -1) return;

      final oldPolygon = _polygons[index];
      final updatedPolygon = oldPolygon.copyWith(
        strokeColor: newColor,
        fillColor: newColor.withValues(alpha: 0.2),
      );

      _polygons[index] = updatedPolygon;

      if (_selectedPolygon?.id == id) {
        _selectedPolygon = updatedPolygon;
      }

      onPolygonUpdated?.call(updatedPolygon);
    } else if (currentMode == DrawMode.circle) {
      final index = _drawableCircles.indexWhere((c) => c.id == id);
      if (index == -1) return;

      final oldCircle = _drawableCircles[index];
      final updatedCircle = oldCircle.copyWith(
        strokeColor: newColor,
        fillColor: newColor.withValues(alpha: 0.2),
      );

      _drawableCircles[index] = updatedCircle;

      if (_selectedCircleId == id) {
        _selectedCircleId = updatedCircle.id;
      }

      onCircleUpdated?.call(updatedCircle);
    } else if (currentMode == DrawMode.rectangle) {
      final index = _rectangles.indexWhere((r) => r.id == id);
      if (index == -1) return;

      final oldRectangle = _rectangles[index];
      final updatedRectangle = oldRectangle.copyWith(
        strokeColor: newColor,
        fillColor: newColor.withValues(alpha: 0.2),
      );

      _rectangles[index] = updatedRectangle;

      if (_selectedRectangleId == id) {
        _selectedRectangleId = updatedRectangle.id;
      }

      onRectangleUpdated?.call(
          updatedRectangle); // Optional: you can add a rectangle update callback
    }

    notifyListeners();
  }

  void setDrawMode(DrawMode mode) {
    finishPolygon();
    finishDrawingRectangle();
    finishFreehandDrawing();
    deselectCircle();
    deselectPolygon();
    deselectRectangle();
    deleteSelectedFreehandPolygon();
    _currentMode = mode;
    _activePolygon = null;
    _selectedPolygon = null;
    notifyListeners();
  }

  double _calculateDistanceMeters(LatLng p1, LatLng p2) {
    const earthRadius = 6371000; // Radius of Earth in meters
    final lat1 = p1.latitude * pi / 180;
    final lat2 = p2.latitude * pi / 180;
    final dLat = (p2.latitude - p1.latitude) * pi / 180;
    final dLng = (p2.longitude - p1.longitude) * pi / 180;

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadius * c;
  }

  // Utility to detect proximity
  bool isNear(LatLng p1, LatLng p2, {double thresholdInMeters = 15}) {
    final distance = Geolocator.distanceBetween(
        p1.latitude, p1.longitude, p2.latitude, p2.longitude);
    return distance < thresholdInMeters;
  }

  bool isSameMarkerTap(LatLng tap, LatLng marker,
      {double thresholdMeters = 10.0}) {
    return _calculateDistanceMeters(tap, marker) < thresholdMeters;
  }

  bool _isPointInsidePolygon(LatLng point, List<LatLng> polygonPoints) {
    int intersectCount = 0;

    for (int j = 0; j < polygonPoints.length - 1; j++) {
      LatLng a = polygonPoints[j];
      LatLng b = polygonPoints[j + 1];

      if (_rayCastIntersect(point, a, b)) {
        intersectCount++;
      }
    }

    return (intersectCount % 2) == 1; // Odd == inside
  }

  bool _rayCastIntersect(LatLng point, LatLng a, LatLng b) {
    double px = point.longitude;
    double py = point.latitude;
    double ax = a.longitude;
    double ay = a.latitude;
    double bx = b.longitude;
    double by = b.latitude;

    if (ay > by) {
      ax = b.longitude;
      ay = b.latitude;
      bx = a.longitude;
      by = a.latitude;
    }

    if (py == ay || py == by) py += 0.00000001;

    if ((py > by || py < ay) || (px > max(ax, bx))) return false;

    if (px < min(ax, bx)) return true;

    double red = (ax != bx) ? ((by - ay) / (bx - ax)) : double.infinity;
    double blue = (ax != px) ? ((py - ay) / (px - ax)) : double.infinity;

    return blue >= red;
  }

  bool selectPolygonAt(LatLng tapPosition) {
    for (final polygon in _polygons) {
      if (_isPointInsidePolygon(tapPosition, polygon.points)) {
        selectPolygon(polygon.id);
        return true;
      }
    }

    deselectPolygon();
    return false;
  }

  void addPolygonPoint(LatLng point) {
    if (_currentMode != DrawMode.polygon) return;

    if (_activePolygon == null) {
      // First tap, start new polygon
      _activePolygon = DrawablePolygon(
          id: UniqueKey().toString(),
          points: [point],
          strokeColor: Colors.transparent);
      _selectedPolygon = _activePolygon;
      _polygons.add(_activePolygon!);

      _activePolyline = DrawablePolyline(
          id: _activePolygon!.id, points: [point], color: currentDrawingColor);
      _polylines.add(_activePolyline!);
    } else {
      final firstPoint = _activePolygon!.points.first;

      // Instead of distance-based snapping, check if user tapped on the first point
      final tappedFirstMarker = isSameMarkerTap(point, firstPoint);

      if (tappedFirstMarker && _activePolygon!.points.length > 2) {
        // Close polygon if tapped on first point
        _activePolygon = _activePolygon!
            .copyWith(points: [..._activePolygon!.points, firstPoint]);
        finishPolygon();
        return;
      }

      final updatedPoints = [..._activePolygon!.points, point];

      _activePolygon = _activePolygon!.copyWith(points: updatedPoints);
      _activePolyline = _activePolyline!.copyWith(points: updatedPoints);

      final polygonIndex =
          _polygons.indexWhere((p) => p.id == _activePolygon!.id);
      if (polygonIndex != -1) _polygons[polygonIndex] = _activePolygon!;

      final polylineIndex =
          _polylines.indexWhere((p) => p.id == _activePolyline!.id);
      if (polylineIndex != -1) _polylines[polylineIndex] = _activePolyline!;

      _selectedPolygon = _activePolygon;
    }

    notifyListeners();
  }

  void handleFirstMarkerTap() {
    if (_currentMode == DrawMode.polygon &&
        _activePolygon != null &&
        _activePolygon!.points.length > 2) {
      finishPolygon();
    }
  }

  double _snapThresholdForZoom(double zoom) {
    // At zoom 0, snap threshold ~300 meters
    // At zoom 21, snap threshold ~0.15 meters
    const baseThreshold = 300.0; // Starting threshold at zoom 0
    final scaleFactor = pow(2, zoom); // 2^zoom scaling factor

    // Dynamically scale the threshold for higher zoom levels, but avoid too small thresholds
    final threshold = baseThreshold / scaleFactor;

    // Prevent threshold from being too small at high zoom levels
    // Cap the threshold between 1 meter and 300 meters for reasonable behavior
    return threshold < 1.0
        ? 1.0
        : threshold > 300.0
            ? 300.0
            : threshold;
  }

  bool isNearPoint(LatLng p1, LatLng p2, double zoom) {
    final threshold = _snapThresholdForZoom(zoom);
    return _calculateDistanceMeters(p1, p2) < threshold;
  }

  void finishPolygon() async {
    if (_activePolygon != null && _activePolygon!.points.length >= 3) {
      final points = _activePolygon!.points;
      final finalizedPolygon = _activePolygon!.copyWith(
          points: points,
          strokeColor: currentDrawingColor,
          fillColor: currentDrawingColor.withValues(alpha: 0.2));
      final index = _polygons.indexWhere((p) => p.id == _activePolygon!.id);
      if (index != -1) _polygons[index] = finalizedPolygon;

      _activePolygon = null;
      _selectedPolygon = finalizedPolygon;

      // Finalize the polyline
      _polylines.removeWhere((p) => p.id == _activePolyline?.id);
      _activePolyline = null;
    }

    // Notify the host app about the drawn polygon(s)
    onPolygonDrawn?.call(_polygons);
    notifyListeners();
  }

  void updatePolygonPoint(String polygonId, int pointIndex, LatLng newPoint) {
    final index = _polygons.indexWhere((p) => p.id == polygonId);
    if (index == -1) return;

    final oldPolygon = _polygons[index];
    final updatedPoints = [...oldPolygon.points];

    if (pointIndex < 0 || pointIndex >= updatedPoints.length) return;

    updatedPoints[pointIndex] = newPoint;

    final updatedPolygon = oldPolygon.copyWith(points: updatedPoints);
    _polygons[index] = updatedPolygon;

    // Update the polyline as well
    final polylineIndex = _polylines.indexWhere((p) => p.id == polygonId);
    if (polylineIndex != -1) {
      _polylines[polylineIndex] =
          _polylines[polylineIndex].copyWith(points: updatedPoints);
    }

    // Update selected polygon if matched
    if (_selectedPolygon?.id == polygonId) {
      _selectedPolygon = updatedPolygon;
    }

    if (_activePolygon?.id == polygonId) {
      _activePolygon = updatedPolygon;
      final activePolylineIndex =
          _polylines.indexWhere((p) => p.id == polygonId);
      if (activePolylineIndex != -1) {
        _activePolyline = _polylines[activePolylineIndex];
      }
    }
    notifyListeners();
    onPolygonUpdated?.call(updatedPolygon);
  }

  LatLng midpoint(LatLng p1, LatLng p2) {
    return LatLng(
        (p1.latitude + p2.latitude) / 2, (p1.longitude + p2.longitude) / 2);
  }

  void _updatePolygon(String polygonId, List<LatLng> newPoints) {
    final index = _polygons.indexWhere((p) => p.id == polygonId);
    if (index == -1) return;

    final oldPolygon = _polygons[index];
    final updatedPolygon = oldPolygon.copyWith(points: newPoints);

    _polygons[index] = updatedPolygon;

    // If the selected polygon is being updated, we need to update it as well.
    if (_selectedPolygon?.id == polygonId) {
      _selectedPolygon = updatedPolygon;
    }

    notifyListeners();
  }

  void updateMidpointPosition(String polygonId, int index, LatLng newPosition) {
    final polygon = _selectedPolygon;
    if (polygon == null) return;

    final points = List<LatLng>.from(polygon.points);
    final prevIndex = (index == 0) ? points.length - 1 : index - 1;
    final nextIndex = (index == points.length - 1) ? 0 : index + 1;

    // Current midpoint between prev and next
    final currentMidpoint = LatLng(
        (points[prevIndex].latitude + points[nextIndex].latitude) / 2,
        (points[prevIndex].longitude + points[nextIndex].longitude) / 2);

    // Calculate delta from current midpoint to new position
    final latDelta = newPosition.latitude - currentMidpoint.latitude;
    final lngDelta = newPosition.longitude - currentMidpoint.longitude;

    // Move both prev and next points slightly toward the new midpoint
    final newPrevPoint = LatLng(points[prevIndex].latitude + latDelta / 2,
        points[prevIndex].longitude + lngDelta / 2);

    final newNextPoint = LatLng(points[nextIndex].latitude + latDelta / 2,
        points[nextIndex].longitude + lngDelta / 2);

    points[prevIndex] = newPrevPoint;
    points[nextIndex] = newNextPoint;

    _updatePolygon(polygonId, points);
  }

  void insertMidpointAsVertex(
      String polygonId, int insertIndex, LatLng newPoint) {
    final index = _polygons.indexWhere((p) => p.id == polygonId);
    if (index == -1) return;

    final polygon = _polygons[index];
    final points = List<LatLng>.from(polygon.points);

    // Insert new point at the correct index
    points.insert(insertIndex, newPoint);

    _updatePolygon(polygonId, points);
  }

  void selectPolygon(String polygonId) {
    if (_selectedPolygon?.id == polygonId) {
      _selectedPolygon = null; // Deselect
    } else {
      _selectedPolygon = _polygons.firstWhereOrNull((p) => p.id == polygonId);
      if (_selectedPolygon != null) {
        onPolygonSelected?.call(_selectedPolygon!);
      }
    }
    notifyListeners();
  }

  Set<Polyline> get mapPolylines {
    return _polylines.map((dp) => dp.toGooglePolyline()).toSet();
  }

  void deselectPolygon() {
    _selectedPolygon = null;
    notifyListeners();
  }

  Set<Polygon> get mapPolygons {
    Set<Polygon> polygons = _polygons.map((polygon) {
      return Polygon(
        polygonId: PolygonId(polygon.id),
        points: polygon.points,
        fillColor: polygon.fillColor.withValues(alpha: 0.2),
        strokeColor: polygon.strokeColor,
        strokeWidth: polygon.strokeWidth,
        consumeTapEvents: true,
        onTap: () => selectPolygon(polygon.id),
      );
    }).toSet();

    // Draw existing rectangles
    for (final rect in rectangles) {
      polygons.add(rect.toPolygon());
    }

    // Draw rectangle in progress
    if (drawingRectangle != null) {
      polygons.add(drawingRectangle!.toPolygon());
    }

    return polygons;
  }

  void clearAll() {
    _polygons.clear();
    _activePolygon = null;
    _selectedPolygon = null;
    notifyListeners();
  }

  void deleteSelectedPolygon() {
    if (_selectedPolygon != null) {
      _polygons.removeWhere((p) => p.id == _selectedPolygon!.id);
      _selectedPolygon = null;
      notifyListeners();
      onPolygonDeleted?.call(_selectedPolygon!.id);
    }
  }

  /// Circle Drawing Logic

  /// Callback for when a circle is drawn
  void Function(List<DrawableCircle> allCircles)? onCircleDrawn;

  /// Called when a circle is selected
  void Function(DrawableCircle selected)? onCircleSelected;

  /// Called when a circle is updated (center or radius or color)
  void Function(DrawableCircle updated)? onCircleUpdated;

  /// Called when a circle is deleted
  void Function(String deletedCircleId)? onCircleDeleted;

  late BitmapDescriptor circleCenterMarkerIcon;
  late BitmapDescriptor circleRadiusHandleIcon;

  final List<DrawableCircle> _drawableCircles = [];
  String? _selectedCircleId;
  DrawableCircle? _selectedCircle;

  DrawableCircle? get selectedCircle =>
      _drawableCircles.firstWhereOrNull((c) => c.id == _selectedCircleId);

  void setCircleCenterMarkerIcon(BitmapDescriptor icon) {
    circleCenterMarkerIcon = icon;
    notifyListeners();
  }

  void setCircleRadiusHandleIcon(BitmapDescriptor icon) {
    circleRadiusHandleIcon = icon;
    notifyListeners();
  }

  void selectCircle(String id) {
    _selectedCircleId = id;
    notifyListeners();
    _selectedCircle = _drawableCircles.firstWhereOrNull((p) => p.id == id);
    if (_selectedCircle != null) {
      onCircleSelected?.call(_selectedCircle!);
    }
  }

  Set<Circle> get mapCircles => _drawableCircles
      .map((e) => e.toCircle(onTap: (pos) => selectCircle(e.id)))
      .toSet();

  void addCircle(LatLng center, double zoom) {
    final id = 'circle_${DateTime.now().millisecondsSinceEpoch}';
    final radius = _initialRadiusFromZoom(zoom);

    final newCircle = DrawableCircle(
        id: id,
        center: center,
        radius: radius,
        strokeColor: _currentDrawingColor,
        fillColor: _currentDrawingColor.withValues(alpha: 0.2));
    _drawableCircles.add(newCircle);
    selectCircle(id);
    onCircleDrawn?.call(_drawableCircles);
    notifyListeners();
  }

  double _initialRadiusFromZoom(double zoom) {
    // Approximate radius in meters based on zoom (tweak as needed)
    // Lower zoom → larger radius, higher zoom → smaller radius
    const zoomToRadius = {
      10: 2000.0,
      11: 1500.0,
      12: 1000.0,
      13: 750.0,
      14: 500.0,
      15: 250.0,
      16: 150.0,
      17: 100.0,
      18: 75.0,
      19: 50.0,
      20: 25.0
    };

    for (final entry in zoomToRadius.entries.toList().reversed) {
      if (zoom >= entry.key) return entry.value;
    }
    return 2000.0; // fallback
  }

  void deselectCircle() {
    _selectedCircleId = null;
    notifyListeners();
  }

  void updateCircleCenter(String id, LatLng newCenter) {
    final index = _drawableCircles.indexWhere((c) => c.id == id);
    if (index == -1) return;

    final updated = _drawableCircles[index].copyWith(center: newCenter);
    _drawableCircles[index] = updated;
    googleMapController?.showMarkerInfoWindow(MarkerId('${id}_radius_handle'));
    notifyListeners();
    onCircleUpdated?.call(updated);
  }

  void updateCircleRadius(String id, LatLng handlePosition) {
    final index = _drawableCircles.indexWhere((c) => c.id == id);
    if (index == -1) return;

    final circle = _drawableCircles[index];
    final newRadius = _calculateDistanceMeters(circle.center, handlePosition);
    final updated = circle.copyWith(radius: newRadius);

    _drawableCircles[index] = updated;
    googleMapController
        ?.showMarkerInfoWindow(MarkerId('${circle.id}_radius_handle'));
    notifyListeners();
    onCircleUpdated?.call(updated);
  }

  /// Place handle due east of center at current radius
  LatLng computeRadiusHandle(LatLng center, double radiusMeters) {
    const double earthRadius = 6371000; // in meters
    final dLat = 0.0;
    final dLng = (radiusMeters / earthRadius) *
        (180 / pi) /
        cos(center.latitude * pi / 180);
    return LatLng(center.latitude + dLat, center.longitude + dLng);
  }

  void deleteSelectedCircle() {
    if (_selectedCircleId != null) {
      final deletedId = _selectedCircleId;
      _drawableCircles.removeWhere((c) => c.id == deletedId);
      _selectedCircleId = null;
      notifyListeners();
      if (deletedId != null) {
        onCircleDeleted?.call(deletedId);
      }
    }
  }

  /// Draw Rectangle Logic

  final List<DrawableRectangle> _rectangles = [];
  DrawableRectangle? _drawingRectangle;
  DrawableRectangle? _selectedRectangle;

  List<DrawableRectangle> get rectangles => _rectangles;
  DrawableRectangle? get drawingRectangle => _drawingRectangle;
  DrawableRectangle? get selectedRectangle => _selectedRectangle;
  String? _selectedRectangleId;
  bool _rectangleStarted = false;
  bool get rectangleStarted => _rectangleStarted;
  String? get selectedRectangleId => _selectedRectangleId;
  void Function(String rectangleId)? onRectangleSelected;
  void Function(DrawableRectangle updated)? onRectangleUpdated;
  void Function(List<DrawableRectangle> finished)? onDrawRectangleFinished;
  void Function(String rectangleId)? onDeleteRectangle;
  late BitmapDescriptor rectangleStartMarkerIcon;
  Marker? _rectangleStartMarker;
  Marker? get rectangleStartMarker => _rectangleStartMarker;

  void setRectangleStartMarkerIcon(BitmapDescriptor icon) {
    rectangleStartMarkerIcon = icon;
    notifyListeners();
  }

  void startDrawingRectangle(LatLng start) {
    final id = 'rectangle_${DateTime.now().millisecondsSinceEpoch}';
    final bounds = LatLngBounds(southwest: start, northeast: start);
    _rectangleStarted = true;
    _drawingRectangle = DrawableRectangle(
        id: id,
        bounds: bounds,
        anchor: start,
        fillColor: _currentDrawingColor.withValues(alpha: 0.2),
        strokeColor: _currentDrawingColor);
    _rectangleStartMarker = Marker(
      markerId: MarkerId('rectangle_start_$id'),
      position: start,
      icon: rectangleStartMarkerIcon,
    );
    notifyListeners();
  }

  void updateDrawingRectangle(LatLng current) {
    if (_drawingRectangle == null) return;

    final anchor = _drawingRectangle!.anchor; // <-- the original start point

    final swLat = min(anchor.latitude, current.latitude);
    final swLng = min(anchor.longitude, current.longitude);

    final neLat = max(anchor.latitude, current.latitude);
    final neLng = max(anchor.longitude, current.longitude);

    final sw = LatLng(swLat, swLng);
    final ne = LatLng(neLat, neLng);

    _drawingRectangle = _drawingRectangle!.copyWith(
      bounds: LatLngBounds(southwest: sw, northeast: ne),
    );
    onRectangleUpdated?.call(_drawingRectangle!);
    notifyListeners();
  }

  void finishDrawingRectangle() {
    if (_drawingRectangle != null) {
      _rectangles.add(_drawingRectangle!);
      _drawingRectangle = null;
      _rectangleStartMarker = null;
      onDrawRectangleFinished?.call(_rectangles);
      _rectangleStarted = false;
      notifyListeners();
    }
  }

  void selectRectangle(String id) {
    if (currentMode != DrawMode.rectangle) {
      return;
    }
    _selectedRectangleId = id;
    _selectedRectangle = _rectangles.firstWhereOrNull((p) => p.id == id);
    notifyListeners();
    if (_selectedRectangle != null) {
      onRectangleSelected?.call(_selectedRectangle!.id);
    }
  }

  void deselectRectangle() {
    if (_selectedRectangleId != null) {
      _selectedRectangleId = null;
      _selectedRectangle = null;
      notifyListeners();
    }
  }

  void deleteSelectedRectangle() {
    if (_selectedRectangleId != null) {
      _rectangles.removeWhere((r) => r.id == _selectedRectangleId);
      onDeleteRectangle?.call(_selectedRectangleId!);
      _selectedRectangleId = null;
      _selectedRectangle = null;
      notifyListeners();
    }
  }

  List<Marker>? _rectangleEditHandles;

  List<Marker> get rectangleEditHandles {
    final rect = selectedRectangle;
    if (rect == null) return [];

    final sw = rect.bounds.southwest;
    final ne = rect.bounds.northeast;
    final nw = LatLng(ne.latitude, sw.longitude);
    final se = LatLng(sw.latitude, ne.longitude);

    _rectangleEditHandles = [
      _buildEditHandle(sw, 'sw'),
      _buildEditHandle(se, 'se'),
      _buildEditHandle(ne, 'ne'),
      _buildEditHandle(nw, 'nw'),
    ];

    return _rectangleEditHandles!;
  }

  LatLng? currentPos;

  Marker _buildEditHandle(LatLng pos, String cornerId) {
    return Marker(
      markerId: MarkerId('handle_$cornerId'),
      position: pos,
      draggable: true,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
      onDragStart: (currentPos) {
        this.currentPos = currentPos;
      },
      onDrag: (updatedPos) {
        _updateRectangleCorner(cornerId, updatedPos);
      },
      onDragEnd: (newPos) {
        _updateRectangleCorner(cornerId, newPos);
      },
    );
  }

  void _updateRectangleCorner(String cornerId, LatLng newPos) {
    final rect = selectedRectangle;
    if (rect == null) return;

    LatLng sw = rect.bounds.southwest;
    LatLng ne = rect.bounds.northeast;

    switch (cornerId) {
      case 'sw':
        sw = LatLng(newPos.latitude, newPos.longitude);
        break;
      case 'se':
        sw = LatLng(newPos.latitude, sw.longitude);
        ne = LatLng(ne.latitude, newPos.longitude);
        break;
      case 'ne':
        ne = LatLng(newPos.latitude, newPos.longitude);
        break;
      case 'nw':
        sw = LatLng(sw.latitude, newPos.longitude);
        ne = LatLng(newPos.latitude, ne.longitude);
        break;
    }

    try {
      final updated = rect.copyWith(
        bounds: LatLngBounds(southwest: sw, northeast: ne),
      );

      final index = _rectangles.indexWhere((r) => r.id == rect.id);
      if (index != -1) {
        _rectangles[index] = updated;
        _selectedRectangle = updated;
        notifyListeners();
      }
    } catch (e) {
      int index = _rectangleEditHandles?.indexWhere(
            (element) => element.markerId.value == 'handle_$cornerId',
          ) ??
          -1;
      if (index >= 0) {
        Marker cornerMarker = _rectangleEditHandles![index];
        _rectangleEditHandles![index] =
            cornerMarker.copyWith(positionParam: currentPos);
        notifyListeners();
      }
    }
  }

  /// Drawing Freehand

  final List<LatLng> _freehandPoints = [];
  bool _isFreehandDrawing = false;
  final List<DrawablePolygon> _freehandPolygons = [];
  List<LatLng> get freehandPoints => _freehandPoints;
  bool get isFreehandDrawing => _isFreehandDrawing;

  String? _selectedFreehandPolygonId;
  List<DrawablePolygon> get freehandPolygons =>
      List.unmodifiable(_freehandPolygons);
  DrawablePolygon? _selectedFreehandPolygon;
  DrawablePolygon? get selectedFreehandPolygon => _selectedFreehandPolygon;
  String? get selectedFreehandPolygonId => _selectedFreehandPolygonId;

  void Function(List<DrawablePolygon> allPolygons)? onFreehandPolygonDrawn;
  void Function(String id)? onFreehandPolygonSelected;
  void Function(String deletedPolygonId)? onFreehandPolygonDeleted;

  bool onPanStarted = false;
  bool onPanEnded = false;

  void startFreehandDrawing() {
    _freehandPoints.clear();
    _isFreehandDrawing = true;
    notifyListeners();
  }

  void addFreehandPoint(LatLng point) {
    if (_isFreehandDrawing) {
      _freehandPoints.add(point);
      notifyListeners();
    }
  }

  void finishFreehandDrawing() {
    if (_isFreehandDrawing && _freehandPoints.length > 2) {
      final id = 'freehand_${DateTime.now().millisecondsSinceEpoch}';
      final polygon = DrawablePolygon(
        id: id,
        points: List<LatLng>.from(_freehandPoints),
        strokeColor: _currentDrawingColor,
        fillColor: _currentDrawingColor.withValues(alpha: 0.2),
      );
      _freehandPolygons.add(polygon);
    }
    _isFreehandDrawing = false;
    _freehandPoints.clear();
    deselectFreehandPolygon();
    notifyListeners();
    onFreehandPolygonDrawn?.call(_freehandPolygons);
  }

  Polygon? get drawingFreehandPolygon {
    if (!_isFreehandDrawing || _freehandPoints.length < 2) return null;

    return Polygon(
      polygonId: PolygonId('freehand_drawing'),
      points: List<LatLng>.from(_freehandPoints),
      strokeColor: Colors.purple,
      strokeWidth: 3,
      fillColor: Colors.purple.withValues(alpha: 0.2),
    );
  }

  void selectFreehandPolygon(String id) {
    if (currentMode != DrawMode.freehand) {
      return;
    }
    _selectedFreehandPolygonId = id;
    _selectedFreehandPolygon =
        _freehandPolygons.firstWhereOrNull((p) => p.id == id);
    notifyListeners();
    if (_selectedFreehandPolygon != null) {
      onFreehandPolygonSelected?.call(_selectedFreehandPolygon!.id);
    }
  }

  void deselectFreehandPolygon() {
    if (_selectedFreehandPolygonId != null) {
      final index = _freehandPolygons
          .indexWhere((p) => p.id == _selectedFreehandPolygonId);
      if (index != -1) {
        _freehandPolygons[index] =
            _freehandPolygons[index].copyWith(strokeWidth: 2);
      }
    }
    _selectedFreehandPolygonId = null;
    notifyListeners();
  }

  void deleteSelectedFreehandPolygon() {
    if (_selectedFreehandPolygonId != null) {
      _freehandPolygons.removeWhere((p) => p.id == _selectedFreehandPolygonId);
      onFreehandPolygonDeleted?.call(_selectedFreehandPolygonId!);
      _selectedFreehandPolygonId = null;
      notifyListeners();
    }
  }

  Set<Polygon> get mapFreeHandPolygons {
    return _freehandPolygons.map((poly) {
      final isSelected = poly.id == _selectedFreehandPolygonId;
      return Polygon(
        polygonId: PolygonId(poly.id),
        points: poly.points,
        strokeColor: isSelected ? Colors.blue : poly.strokeColor,
        fillColor:
            isSelected ? Colors.blue.withValues(alpha: 0.2) : poly.fillColor,
        strokeWidth: isSelected ? 4 : 2,
        consumeTapEvents: true,
        onTap: () => selectFreehandPolygon(poly.id),
      );
    }).toSet();
  }

  drawShapesFromGeoJson(Map<String, dynamic> geoJson) {
    final shapesBundle = drawableShapesFromGeoJson(geoJson);
    _polygons.addAll(shapesBundle.polygons);
    _rectangles.addAll(shapesBundle.rectangles);
    _drawableCircles.addAll(shapesBundle.circles);
  }

  Map<String, dynamic> geoJsonFromDrawableShapes() {
    return exportToGeoJson(
      polygons: _polygons,
      rectangles: _rectangles,
      circles: _drawableCircles,
    );
  }
}
