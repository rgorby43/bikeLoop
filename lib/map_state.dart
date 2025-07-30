import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:vector_math/vector_math.dart' as vector;
import 'package:url_launcher/url_launcher.dart';
import 'package:geocoding/geocoding.dart';
import 'secrets.dart';

class MapState with ChangeNotifier {
  // --- Private State ---
  GoogleMapController? _mapController;
  Position? _currentPosition;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  String _targetDistanceStr = "10";
  bool _isSmartMode = true;
  bool _isLoading = false;
  String? _errorMessage;
  Map<String, dynamic>? _routeInfo;
  double _currentRadiusFactor = 1.0;
  bool _endNearRestaurant = false;
  LatLng? _finalRestaurantLocation;

  // --- State for new features ---
  LatLng? _customStartLocation;
  LatLng? _lastGeneratedStartPoint;
  List<LatLng> _lastGeneratedWaypoints = [];
  final TextEditingController customStartController = TextEditingController();
  final TextEditingController distanceController = TextEditingController(text: "10");

  // --- Public Getters ---
  LatLng? get initialCameraPosition => _currentPosition != null
      ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
      : const LatLng(38.5358, -105.9910); // Salida, CO fallback
  Set<Marker> get markers => _markers;
  Set<Polyline> get polylines => _polylines;
  bool get isSmartMode => _isSmartMode;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  Map<String, dynamic>? get routeInfo => _routeInfo;
  String get targetDistanceStr => _targetDistanceStr;
  bool get endNearRestaurant => _endNearRestaurant;

  // --- Constants ---
  static const double _metersPerMile = 1609.34;
  static const int _maxRetriesSmartMode = 50;
  static const double _radiusAdjustmentStep = 0.15;

  MapState() {
    _init();
    distanceController.addListener(() {
      _targetDistanceStr = distanceController.text;
    });
  }

  Future<void> _init() async {
    await _getCurrentLocation();
  }

  void onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    if (_currentPosition != null) {
      _animateToUser();
    }
  }

  void setSmartMode(bool value) {
    _isSmartMode = value;
    notifyListeners();
  }

  void setEndNearRestaurant(bool value) {
    _endNearRestaurant = value;
    notifyListeners();
  }

  Future<void> _getCurrentLocation() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception("Location permissions are denied.");
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception("Location permissions are permanently denied.");
      }

      _currentPosition = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      if (_customStartLocation == null && _currentPosition != null) {
        _updateStartMarker(
            LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            'Start/End (Your Location)');
        if (_mapController != null) {
          _animateToUser();
        }
      } else if (_currentPosition == null) {
        throw Exception("Failed to get current position.");
      }
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _updateStartMarker(LatLng position, String title) {
    _markers.removeWhere((m) => m.markerId.value == 'start');
    _markers.add(
      Marker(
        markerId: const MarkerId('start'),
        position: position,
        infoWindow: InfoWindow(title: title),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      ),
    );
  }

  Future<void> setCustomStartLocation(LatLng position) async {
    _isLoading = true;
    notifyListeners();
    try {
      _customStartLocation = position;
      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        customStartController.text = "${p.street}, ${p.locality}";
      } else {
        customStartController.text = "Custom Location Selected";
      }

      _updateStartMarker(position, 'Custom Start/End');
      _mapController?.animateCamera(CameraUpdate.newLatLng(position));

    } catch (e) {
      customStartController.text = "Address not found";
      _updateStartMarker(position, 'Custom Start/End');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearCustomStartLocation() {
    _customStartLocation = null;
    customStartController.clear();
    if (_currentPosition != null) {
      _updateStartMarker(
          LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          'Start/End (Your Location)');
      _animateToUser();
    } else {
      _markers.removeWhere((m) => m.markerId.value == 'start');
    }
    notifyListeners();
  }

  void _animateToUser() {
    if (_mapController != null && _currentPosition != null) {
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            zoom: 13.0,
          ),
        ),
      );
    }
  }

  Future<void> generateLoop() async {
    _isLoading = true;
    _errorMessage = null;
    _polylines.clear();
    _routeInfo = null;
    _finalRestaurantLocation = null;
    _markers.removeWhere((m) => m.markerId.value != 'start');
    _currentRadiusFactor = 1.0;
    _lastGeneratedStartPoint = null;
    _lastGeneratedWaypoints.clear();
    notifyListeners();

    final LatLng? startPoint = _customStartLocation ?? (_currentPosition != null
        ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
        : null);

    if (startPoint == null) {
      await _getCurrentLocation();
      if (_currentPosition == null) {
        _errorMessage = "Could not get your location. Please enable location services or select a custom start point by long-pressing on the map.";
        _isLoading = false;
        notifyListeners();
        return;
      }
    }

    final LatLng effectiveStartPoint = _customStartLocation ?? LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

    final double? targetDistMiles = double.tryParse(distanceController.text);
    if (targetDistMiles == null || targetDistMiles <= 0) {
      _errorMessage = "Please enter a valid distance.";
      _isLoading = false;
      notifyListeners();
      return;
    }
    final double targetDistMeters = targetDistMiles * _metersPerMile;

    try {
      List<LatLng> generatedWaypoints;
      List<LatLng> finalWaypoints = [];
      Map<String, dynamic>? result;
      bool routeFound = false;
      int retries = 0;

      do {
        _markers.removeWhere((m) => m.markerId.value.startsWith('wp_') || m.markerId.value == 'restaurant');
        int pointsToGenerate = _endNearRestaurant ? 2 : 3;
        generatedWaypoints = _generateStructuredWaypoints(effectiveStartPoint, targetDistMeters, _currentRadiusFactor, pointsToGenerate);
        final List<LatLng>? snappedWaypoints = await _snapWaypointsToRoads(generatedWaypoints);

        if (snappedWaypoints == null) {
          retries++;
          await Future.delayed(const Duration(milliseconds: 150));
          continue;
        }

        finalWaypoints = List.from(snappedWaypoints);

        if (_endNearRestaurant && finalWaypoints.isNotEmpty) {
          LatLng lastWp = finalWaypoints.removeLast();
          _finalRestaurantLocation = await _findNearbyRestaurant(lastWp);

          if (_finalRestaurantLocation != null) {
            finalWaypoints.add(_finalRestaurantLocation!);
          } else {
            finalWaypoints.add(lastWp);
          }
        }

        result = await _getDirections(effectiveStartPoint, effectiveStartPoint, finalWaypoints);

        if (result != null) {
          final double actualDistanceMeters = (result['distance_meters'] as num).toDouble();
          if (!_isSmartMode) {
            routeFound = true;
          } else {
            double lowerBound = targetDistMeters * 0.9;
            double upperBound = targetDistMeters * 1.1;

            if (actualDistanceMeters >= lowerBound && actualDistanceMeters <= upperBound) {
              routeFound = true;
            } else {
              if (actualDistanceMeters < lowerBound) {
                _currentRadiusFactor += _radiusAdjustmentStep;
              } else {
                _currentRadiusFactor -= _radiusAdjustmentStep;
                if (_currentRadiusFactor < 0.1) _currentRadiusFactor = 0.1;
              }
              retries++;
              await Future.delayed(const Duration(milliseconds: 150));
            }
          }
        } else {
          retries++;
          await Future.delayed(const Duration(milliseconds: 150));
        }
      } while (!_isSmartMode && !routeFound || _isSmartMode && !routeFound && retries < _maxRetriesSmartMode);

      if (routeFound && result != null) {
        _lastGeneratedStartPoint = effectiveStartPoint;
        _lastGeneratedWaypoints = finalWaypoints;
        _processRouteResult(result, finalWaypoints);
        _animateToRouteBounds(result['bounds']);
      } else {
        _errorMessage = "Sorry, couldn't generate a loop. Try a different distance or starting point.";
      }
    } catch (e) {
      _errorMessage = "An unexpected error occurred.";
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Replace your function with this final version.
  Future<void> startNavigation() async {
    if (_lastGeneratedStartPoint == null) {
      _errorMessage = "No route has been generated yet.";
      notifyListeners();
      return;
    }

    final LatLng origin = _lastGeneratedStartPoint!;
    final LatLng destination = _lastGeneratedStartPoint!; // Loop returns to origin
    final List<LatLng> waypoints = _lastGeneratedWaypoints;

    // This is the official, universal URL format for multi-stop routes.
    // On a phone with Google Maps installed, it will open in the app.
    // Otherwise, it will open in the browser.
    final Uri uri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'origin': '${origin.latitude},${origin.longitude}',
      'destination': '${destination.latitude},${destination.longitude}',
      'waypoints': waypoints.map((p) => '${p.latitude},${p.longitude}').join('|'),
      'travelmode': 'bicycling',
    });

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw 'Could not launch $uri';
      }
    } catch (e) {
      _errorMessage = "Could not launch Google Maps.";
      notifyListeners();
    }
  }

  List<LatLng> _generateStructuredWaypoints(LatLng start, double targetDistanceMeters, double radiusFactor, int numPoints) {
    final Random random = Random();
    final List<LatLng> waypoints = [];

    final double baseRadiusFraction = 0.35;
    final double roughRadiusMeters = (targetDistanceMeters * baseRadiusFraction * radiusFactor) / 2;
    final double minRadius = 200.0;
    final double maxRadius = targetDistanceMeters * 0.8;
    final double adjustedRadius = roughRadiusMeters.clamp(minRadius, maxRadius);

    const double earthRadius = 6371000.0;
    double initialBearing = random.nextDouble() * 2 * pi;

    double totalArc = (pi * 1.5);
    double angleIncrement = totalArc / (numPoints + 1);

    for (int i = 0; i < numPoints; i++) {
      double currentBearing = initialBearing + (angleIncrement * (i + 1));
      double distance = adjustedRadius * (0.6 + (random.nextDouble() * 0.4));

      double lat1Rad = vector.radians(start.latitude);
      double lon1Rad = vector.radians(start.longitude);
      double lat2Rad = asin(sin(lat1Rad) * cos(distance / earthRadius) +
          cos(lat1Rad) * sin(distance / earthRadius) * cos(currentBearing));
      double lon2Rad = lon1Rad + atan2(sin(currentBearing) * sin(distance / earthRadius) * cos(lat1Rad),
          cos(distance / earthRadius) - sin(lat1Rad) * sin(lat2Rad));
      waypoints.add(LatLng(vector.degrees(lat2Rad), vector.degrees(lon2Rad)));
    }
    return waypoints;
  }

  Future<List<LatLng>?> _snapWaypointsToRoads(List<LatLng> waypoints) async {
    final String path = waypoints.map((p) => '${p.latitude},${p.longitude}').join('|');
    final Map<String, String> queryParams = {
      'path': path,
      'key': googleApiKey,
    };
    final Uri url = Uri.https('roads.googleapis.com', '/v1/snapToRoads', queryParams);

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data.containsKey('snappedPoints')) {
          final List snappedPoints = data['snappedPoints'];
          final List<LatLng> validPoints = [];
          for (var point in snappedPoints) {
            if (point != null && point['location'] != null) {
              final location = point['location'];
              if (location['latitude'] != null && location['longitude'] != null) {
                validPoints.add(LatLng(
                  (location['latitude'] as num).toDouble(),
                  (location['longitude'] as num).toDouble(),
                ));
              }
            }
          }
          return validPoints.isNotEmpty ? validPoints : null;
        }
      }
    } catch (e) {
      // Fail silently
    }
    return null;
  }

  Future<LatLng?> _findNearbyRestaurant(LatLng searchCenter) async {
    const String placesBaseUrl = "https://maps.googleapis.com/maps/api/place/nearbysearch/json";
    const double searchRadiusMeters = 1500;
    final Map<String, String> queryParams = {
      'location': '${searchCenter.latitude},${searchCenter.longitude}',
      'radius': searchRadiusMeters.toString(),
      'type': 'restaurant',
      'opennow': 'true',
      'key': googleApiKey,
      'rankby': 'prominence'
    };
    final bool useCorsProxy = kIsWeb;
    final String corsProxy = "https://cors-anywhere.herokuapp.com/";
    Uri url;

    if (useCorsProxy) {
      final String googleUrl = Uri.https('maps.googleapis.com', '/maps/api/place/nearbysearch/json', queryParams).toString();
      url = Uri.parse(corsProxy + googleUrl.substring(8));
    } else {
      url = Uri.https('maps.googleapis.com', '/maps/api/place/nearbysearch/json', queryParams);
    }

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if ((data['status'] == 'OK' || data['status'] == 'ZERO_RESULTS') && data['results'] != null) {
          if (data['results'].isNotEmpty) {
            final place = data['results'][0];
            final location = place['geometry']['location'];
            return LatLng(
                (location['lat'] as num).toDouble(),
                (location['lng'] as num).toDouble()
            );
          }
        }
      }
    } catch (e) {
      // Fail silently
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getDirections(
      LatLng origin, LatLng destination, List<LatLng> waypoints) async {
    const String url = 'https://routes.googleapis.com/directions/v2:computeRoutes';
    final Map<String, dynamic> requestBody = {
      'origin': {'location': {'latLng': {'latitude': origin.latitude, 'longitude': origin.longitude}}},
      'destination': {'location': {'latLng': {'latitude': destination.latitude, 'longitude': destination.longitude}}},
      'intermediates': waypoints.map((wp) => {'location': {'latLng': {'latitude': wp.latitude, 'longitude': wp.longitude}}}).toList(),
      'travelMode': 'BICYCLE',
    };
    final Map<String, String> headers = {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': googleApiKey,
      'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters,routes.polyline,routes.viewport',
    };

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: headers,
        body: json.encode(requestBody),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final String durationStr = route['duration'];
          final int durationSeconds = int.parse(durationStr.replaceAll('s', ''));
          final String polylinePoints = route['polyline']['encodedPolyline'];
          final LatLngBounds bounds = LatLngBounds(
            southwest: LatLng(
              (route['viewport']['low']['latitude'] as num).toDouble(),
              (route['viewport']['low']['longitude'] as num).toDouble(),
            ),
            northeast: LatLng(
              (route['viewport']['high']['latitude'] as num).toDouble(),
              (route['viewport']['high']['longitude'] as num).toDouble(),
            ),
          );

          return {
            'polyline_points': polylinePoints,
            'distance_meters': route['distanceMeters'],
            'duration_seconds': durationSeconds,
            'bounds': bounds,
          };
        }
      }
    } catch (e) {
      // Fail silently
    }
    return null;
  }

  void _processRouteResult(Map<String, dynamic> result, List<LatLng> waypoints) {
    List<PointLatLng> decodedPoints = PolylinePoints().decodePolyline(result['polyline_points']);
    List<LatLng> polylineCoordinates = decodedPoints.map((p) => LatLng(p.latitude, p.longitude)).toList();
    Polyline routePolyline = Polyline(
      polylineId: const PolylineId('route'),
      color: Colors.blueAccent,
      points: polylineCoordinates,
      width: 5,
    );
    _polylines.clear();
    _polylines.add(routePolyline);

    _routeInfo = {
      'distance': (result['distance_meters'] / _metersPerMile).toStringAsFixed(1),
      'time': (result['duration_seconds'] / 60).toStringAsFixed(0),
    };

    for (int i = 0; i < waypoints.length; i++) {
      bool isRestaurant = _finalRestaurantLocation != null &&
          waypoints[i].latitude == _finalRestaurantLocation!.latitude &&
          waypoints[i].longitude == _finalRestaurantLocation!.longitude;

      _markers.add(Marker(
        markerId: MarkerId(isRestaurant ? 'restaurant' : 'wp_$i'),
        position: waypoints[i],
        infoWindow: InfoWindow(title: isRestaurant ? 'Restaurant Stop' : 'Point ${i + 1}'),
        icon: BitmapDescriptor.defaultMarkerWithHue(
            isRestaurant ? BitmapDescriptor.hueViolet : BitmapDescriptor.hueOrange
        ),
      ));
    }
  }

  void _animateToRouteBounds(LatLngBounds bounds) {
    if (_mapController != null) {
      _mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 60.0)
      );
    }
  }

  @override
  void dispose() {
    distanceController.dispose();
    customStartController.dispose();
    super.dispose();
  }
}