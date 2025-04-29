// lib/map_state.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
// Correct import for the package:
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:vector_math/vector_math.dart' as vector;
import 'secrets.dart';

class MapState with ChangeNotifier {
  // --- Private State ---
  GoogleMapController? _mapController;
  Position? _currentPosition;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  String _targetDistanceStr = "10";
  bool _isSmartMode = false;
  bool _isLoading = false;
  String? _errorMessage;
  Map<String, dynamic>? _routeInfo;

  // --- Public Getters ---
  // Use Bozeman, MT as a fallback if location not yet available
  LatLng? get initialCameraPosition => _currentPosition != null
      ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
      : const LatLng(45.6770, -111.0429); // Bozeman approx LatLng
  Set<Marker> get markers => _markers;
  Set<Polyline> get polylines => _polylines;
  bool get isSmartMode => _isSmartMode;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  Map<String, dynamic>? get routeInfo => _routeInfo;
  String get targetDistanceStr => _targetDistanceStr;

  // --- Controller ---
  final TextEditingController distanceController = TextEditingController(text: "10");

  // --- Constants ---
  static const double _metersPerMile = 1609.34;
  static const int _maxRetriesSmartMode = 5;

  // --- Initialization ---
  MapState() {
    _init();
    distanceController.addListener(() {
      _targetDistanceStr = distanceController.text;
    });
  }

  Future<void> _init() async {
    await _getCurrentLocation();
  }

  // --- Methods ---
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

  Future<void> _getCurrentLocation() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception(
              "Location permissions are denied. Please enable them.");
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception(
            "Location permissions are permanently denied. Please enable them in settings.");
      }

      _currentPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);

      _markers.clear();
      _markers.add(
        Marker(
          markerId: const MarkerId('start'),
          position: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          infoWindow: const InfoWindow(title: 'Start/End'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      );

      if (_mapController != null) {
        _animateToUser();
      }
    } catch (e) {
      _errorMessage = "Error getting location: ${e.toString()}";
      print(_errorMessage);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
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
    // Reset previous state
    _isLoading = true;
    _errorMessage = null;
    _polylines.clear();
    _routeInfo = null;
    _markers.removeWhere((m) => m.markerId.value != 'start'); // Keep only start marker
    notifyListeners(); // Show loading, clear old route

    if (_currentPosition == null) {
      _errorMessage = "Current location not available. Trying again...";
      notifyListeners();
      await _getCurrentLocation();
      if (_currentPosition == null){
        _errorMessage = "Failed to get current location. Please ensure location services are enabled and permissions granted.";
        _isLoading = false;
        notifyListeners();
        return;
      }
      // If location is now available, proceed, otherwise error is already set
    }


    final double? targetDistMiles = double.tryParse(distanceController.text);
    if (targetDistMiles == null || targetDistMiles <= 0) {
      _errorMessage = "Please enter a valid positive distance.";
      _isLoading = false;
      notifyListeners();
      return;
    }
    final double targetDistMeters = targetDistMiles * _metersPerMile;


    try {
      LatLng startPoint = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
      List<LatLng> waypoints;
      Map<String, dynamic>? result;
      bool routeFound = false;
      int retries = 0;

      do {
        waypoints = _generateWaypoints(startPoint, targetDistMeters);
        // Ensure generated waypoints are cleared from markers on retry
        if (retries > 0) {
          _markers.removeWhere((m) => m.markerId.value.startsWith('wp_'));
        }
        result = await _getDirections(startPoint, startPoint, waypoints);

        if (result != null) {
          final double actualDistanceMeters = result['distance_meters'];
          if (!_isSmartMode) {
            routeFound = true;
          } else {
            double lowerBound = targetDistMeters * 0.9;
            double upperBound = targetDistMeters * 1.1;
            if (actualDistanceMeters >= lowerBound && actualDistanceMeters <= upperBound) {
              routeFound = true;
            } else {
              print("Smart Mode Retry ${retries+1}: Target=${targetDistMeters.toStringAsFixed(0)}m, Actual=${actualDistanceMeters.toStringAsFixed(0)}m.");
              retries++;
              await Future.delayed(const Duration(milliseconds: 150));
            }
          }
        } else {
          // Error occurred in _getDirections, break loop
          retries = _maxRetriesSmartMode; // Force exit
        }
      } while (!_isSmartMode && !routeFound || // Simple mode loop runs once if result is valid
          _isSmartMode && !routeFound && retries < _maxRetriesSmartMode);


      if (routeFound && result != null) {
        _processRouteResult(result, waypoints); // Pass waypoints to add markers correctly
        _animateToRouteBounds(result['bounds']);
      } else if (_isSmartMode && !routeFound && result != null) {
        _errorMessage = "Couldn't generate a loop close to the target distance (${(result['distance_meters'] / _metersPerMile).toStringAsFixed(1)} mi found). Try a different distance or Simple Mode.";
      } else if (result == null) {
        // Error message should already be set by _getDirections
        if (_errorMessage == null) { // Fallback error
          _errorMessage = "Failed to get route from Google Directions API.";
        }
      }

    } catch (e) {
      _errorMessage = "Error generating loop: ${e.toString()}";
      print(_errorMessage);
    } finally {
      _isLoading = false;
      notifyListeners(); // Update UI with result/error
    }
  }

  List<LatLng> _generateWaypoints(LatLng start, double targetDistanceMeters) {
    final Random random = Random();
    final int numPoints = 2 + random.nextInt(2); // 2 or 3 intermediate points
    final List<LatLng> waypoints = [];
    final double radiusFraction = _isSmartMode ? 0.25 : 0.33;
    final double roughRadiusMeters = (targetDistanceMeters * radiusFraction) / 2;
    const double earthRadius = 6371000.0;

    for (int i = 0; i < numPoints; i++) {
      double angle = random.nextDouble() * 2 * pi;
      double distance = roughRadiusMeters * (0.5 + random.nextDouble() * 0.5);
      double lat1Rad = vector.radians(start.latitude);
      double lon1Rad = vector.radians(start.longitude);
      double lat2Rad = asin(sin(lat1Rad) * cos(distance / earthRadius) +
          cos(lat1Rad) * sin(distance / earthRadius) * cos(angle));
      double lon2Rad = lon1Rad + atan2(sin(angle) * sin(distance / earthRadius) * cos(lat1Rad),
          cos(distance / earthRadius) - sin(lat1Rad) * sin(lat2Rad));
      waypoints.add(LatLng(vector.degrees(lat2Rad), vector.degrees(lon2Rad)));
    }
    return waypoints;
  }


  Future<Map<String, dynamic>?> _getDirections(
      LatLng origin, LatLng destination, List<LatLng> waypoints) async {
    final String waypointsString = waypoints
        .map((wp) => 'via:${wp.latitude},${wp.longitude}')
        .join('|');
    final Uri url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json?'
            'origin=${origin.latitude},${origin.longitude}'
            '&destination=${destination.latitude},${destination.longitude}'
            '&waypoints=optimize:true|$waypointsString'
            '&mode=bicycling'
            '&key=$googleApiKey');

    print("Directions API URL: $url");

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          int totalDistanceMeters = 0;
          int totalDurationSeconds = 0;
          int totalTurns = 0;
          for (var leg in route['legs']) {
            totalDistanceMeters += leg['distance']['value'] as int;
            totalDurationSeconds += leg['duration']['value'] as int;
            totalTurns += (leg['steps'] as List).length;
          }
          String polylinePoints = route['overview_polyline']['points'];
          LatLngBounds bounds = LatLngBounds(
            southwest: LatLng(route['bounds']['southwest']['lat'], route['bounds']['southwest']['lng']),
            northeast: LatLng(route['bounds']['northeast']['lat'], route['bounds']['northeast']['lng']),
          );
          return {
            'polyline_points': polylinePoints,
            'distance_meters': totalDistanceMeters,
            'duration_seconds': totalDurationSeconds,
            'turns': totalTurns,
            'bounds': bounds,
          };
        } else {
          _errorMessage = "Directions API Error: ${data['status']} ${data['error_message'] ?? ''}";
          print(_errorMessage);
          return null;
        }
      } else {
        _errorMessage = "HTTP Error: ${response.statusCode} ${response.reasonPhrase}";
        print(_errorMessage);
        return null;
      }
    } catch (e) {
      _errorMessage = "Network or parsing error: ${e.toString()}";
      print(_errorMessage);
      return null;
    }
  }

  void _processRouteResult(Map<String, dynamic> result, List<LatLng> waypoints) {
    List<PointLatLng> decodedPoints = PolylinePoints().decodePolyline(result['polyline_points']);
    List<LatLng> polylineCoordinates = decodedPoints.map((p) => LatLng(p.latitude, p.longitude)).toList();

    Polyline routePolyline = Polyline(
      polylineId: const PolylineId('route'),
      color: Colors.blue,
      points: polylineCoordinates,
      width: 5,
    );
    _polylines.add(routePolyline);

    _routeInfo = {
      'distance': (result['distance_meters'] / _metersPerMile).toStringAsFixed(1),
      'time': (result['duration_seconds'] / 60).toStringAsFixed(0),
      'turns': result['turns'],
    };

    // Add markers for the intermediate waypoints
    for (int i = 0; i < waypoints.length; i++) {
      _markers.add(Marker(
        markerId: MarkerId('wp_$i'),
        position: waypoints[i],
        infoWindow: InfoWindow(title: 'Point ${i + 1}'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
      ));
    }
  }

  void _animateToRouteBounds(LatLngBounds bounds) {
    if (_mapController != null) {
      _mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 60.0) // Increased padding
      );
    }
  }

  @override
  void dispose() {
    distanceController.dispose();
    super.dispose();
  }
}