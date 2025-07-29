// lib/map_state.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
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
  bool _isSmartMode = true;
  bool _isLoading = false;
  String? _errorMessage;
  Map<String, dynamic>? _routeInfo;
  double _currentRadiusFactor = 1.0;

  bool _endNearRestaurant = false;
  LatLng? _finalRestaurantLocation;

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


  final TextEditingController distanceController = TextEditingController(text: "10");
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
          throw Exception("Location permissions are denied. Please enable them.");
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception("Location permissions are permanently denied. Please enable them in settings.");
      }

      _currentPosition = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      print("Current Location: ${_currentPosition?.latitude}, ${_currentPosition?.longitude}");

      _markers.clear();
      if (_currentPosition != null) {
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
      } else {
        throw Exception("Failed to get current position.");
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
    _isLoading = true;
    _errorMessage = null;
    _polylines.clear();
    _routeInfo = null;
    _finalRestaurantLocation = null;
    _markers.removeWhere((m) => m.markerId.value != 'start');
    _currentRadiusFactor = 1.0;
    notifyListeners();

    if (_currentPosition == null) {
      _errorMessage = "Current location not available. Trying again...";
      notifyListeners();
      await _getCurrentLocation();
      if (_currentPosition == null) {
        _errorMessage = "Failed to get current location. Please ensure location services are enabled and permissions granted.";
        _isLoading = false;
        notifyListeners();
        return;
      }
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
      List<LatLng> generatedWaypoints;
      List<LatLng> finalWaypoints = [];
      Map<String, dynamic>? result;
      bool routeFound = false;
      int retries = 0;

      do {
        _markers.removeWhere((m) => m.markerId.value.startsWith('wp_') || m.markerId.value == 'restaurant');

        int pointsToGenerate = _endNearRestaurant ? 2 : 3;
        generatedWaypoints = _generateStructuredWaypoints(startPoint, targetDistMeters, _currentRadiusFactor, pointsToGenerate);

        // --- NEW: Snap generated points to the nearest roads ---
        final List<LatLng>? snappedWaypoints = await _snapWaypointsToRoads(generatedWaypoints);

        if (snappedWaypoints == null) {
          retries++;
          print("Waypoint snapping failed. Retrying...");
          await Future.delayed(const Duration(milliseconds: 150));
          continue; // Skip to the next iteration of the loop
        }

        finalWaypoints = List.from(snappedWaypoints);

        if (_endNearRestaurant && finalWaypoints.isNotEmpty) {
          LatLng lastWp = finalWaypoints.removeLast();
          _finalRestaurantLocation = await _findNearbyRestaurant(lastWp);

          if (_finalRestaurantLocation != null) {
            finalWaypoints.add(_finalRestaurantLocation!);
            print("Restaurant found near last waypoint: $_finalRestaurantLocation");
          } else {
            finalWaypoints.add(lastWp);
            print("Could not find nearby restaurant, using original last waypoint.");
          }
        }

        result = await _getDirections(startPoint, startPoint, finalWaypoints);

        if (result != null) {
          final double actualDistanceMeters = (result['distance_meters'] as num).toDouble();
          if (!_isSmartMode) {
            routeFound = true;
          } else {
            double lowerBound = targetDistMeters * 0.9;
            double upperBound = targetDistMeters * 1.1;

            if (actualDistanceMeters >= lowerBound && actualDistanceMeters <= upperBound) {
              routeFound = true;
              print("Smart Mode: Route found within tolerance! (${(actualDistanceMeters / _metersPerMile).toStringAsFixed(1)} mi)");
            } else {
              if (actualDistanceMeters < lowerBound) {
                _currentRadiusFactor += _radiusAdjustmentStep;
                print("Smart Mode Retry ${retries + 1}: Route too short (${(actualDistanceMeters / _metersPerMile).toStringAsFixed(1)} mi). Increasing radius factor to ${_currentRadiusFactor.toStringAsFixed(2)}.");
              } else {
                _currentRadiusFactor -= _radiusAdjustmentStep;
                if (_currentRadiusFactor < 0.1) _currentRadiusFactor = 0.1;
                print("Smart Mode Retry ${retries + 1}: Route too long (${(actualDistanceMeters / _metersPerMile).toStringAsFixed(1)} mi). Decreasing radius factor to ${_currentRadiusFactor.toStringAsFixed(2)}.");
              }
              retries++;
              await Future.delayed(const Duration(milliseconds: 150));
            }
          }
        } else {
          print("Smart Mode Retry ${retries + 1}: _getDirections failed (Status: ${_errorMessage ?? 'Unknown Error'}). Trying new points.");
          retries++;
          await Future.delayed(const Duration(milliseconds: 150));
        }
      } while (!_isSmartMode && !routeFound || _isSmartMode && !routeFound && retries < _maxRetriesSmartMode);

      if (routeFound && result != null) {
        _processRouteResult(result, finalWaypoints);
        _animateToRouteBounds(result['bounds']);
      } else if (_isSmartMode && !routeFound) {
        String finalDistMsg = result != null ? "Last attempt distance: ${(result['distance_meters'] / _metersPerMile).toStringAsFixed(1)} mi." : "Could not generate a valid route.";
        _errorMessage = "Smart Loop failed after $retries attempts. $finalDistMsg Try a different distance or Simple Mode.";
        print(_errorMessage);
      } else if (result == null && _errorMessage == null) {
        _errorMessage = "Failed to get route. Check network or API keys.";
      }

    } catch (e, s) {
      _errorMessage = "Error generating loop: ${e.toString()}";
      print(_errorMessage);
      print('--- STACK TRACE ---');
      print(s);
    } finally {
      _isLoading = false;
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

    print("Generating $numPoints structured waypoints with adjusted radius: ${adjustedRadius.toStringAsFixed(0)}m (Factor: ${radiusFactor.toStringAsFixed(2)})");

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

// lib/map_state.dart

  Future<List<LatLng>?> _snapWaypointsToRoads(List<LatLng> waypoints) async {
    final String path = waypoints.map((p) => '${p.latitude},${p.longitude}').join('|');

    final Map<String, String> queryParams = {
      'path': path,
      'key': googleApiKey,
    };

    final Uri url = Uri.https('roads.googleapis.com', '/v1/snapToRoads', queryParams);

    print("Roads API URL: $url");

    try {
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data.containsKey('snappedPoints')) {
          final List snappedPoints = data['snappedPoints'];

          // --- SAFER PARSING LOGIC ---
          final List<LatLng> validPoints = [];
          for (var point in snappedPoints) {
            // Check if the point and its location data exist before using them
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
        } else {
          _errorMessage = "Roads API Error: ${data['error']?['message'] ?? 'No snapped points returned.'}";
          print(_errorMessage);
          return null;
        }
      } else {
        _errorMessage = "Roads API HTTP Error: ${response.statusCode}";
        print(_errorMessage);
        return null;
      }
    } catch (e) {
      _errorMessage = "Roads API Network Error: ${e.toString()}";
      print(_errorMessage);
      return null;
    }
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
    print("Places API URL: $url");

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (useCorsProxy && response.body.contains("Missing required request header")) {
          _errorMessage = "CORS Proxy Error (Places API): Missing required headers.";
          print(_errorMessage);
          return null;
        }

        if ((data['status'] == 'OK' || data['status'] == 'ZERO_RESULTS') && data['results'] != null) {
          if (data['results'].isNotEmpty) {
            final place = data['results'][0];
            final location = place['geometry']['location'];
            return LatLng(
                (location['lat'] as num).toDouble(),
                (location['lng'] as num).toDouble()
            );
          } else {
            print("Places API: Zero results found for restaurants nearby.");
            _errorMessage = "No open restaurants found near the end of the loop.";
            return null;
          }
        } else {
          _errorMessage = "Places API Error: ${data['status']} ${data['error_message'] ?? ''}";
          print(_errorMessage);
          return null;
        }
      } else {
        _errorMessage = "Places API HTTP Error: ${response.statusCode} ${response.reasonPhrase}";
        print(_errorMessage);
        return null;
      }
    } catch (e) {
      _errorMessage = "Places API Network/Parsing Error: ${e.toString()}";
      print(_errorMessage);
      return null;
    }
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
        } else {
          _errorMessage = "Routes API Error: No routes found.";
          print(_errorMessage);
          return null;
        }
      } else {
        _errorMessage = "Routes API HTTP Error: ${response.statusCode} - ${response.body}";
        print(_errorMessage);
        return null;
      }
    } catch (e, s) {
      _errorMessage = "Routes API Network/Parsing Error: ${e.toString()}";
      print(_errorMessage);
      print(s);
      return null;
    }
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
    super.dispose();
  }
}