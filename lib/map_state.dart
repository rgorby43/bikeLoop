// lib/map_state.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
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
  double _currentRadiusFactor = 1.0;

  // *** NEW: State for restaurant feature ***
  bool _endNearRestaurant = false;
  LatLng? _finalRestaurantLocation; // Store found restaurant location

  // --- Public Getters ---
  LatLng? get initialCameraPosition => _currentPosition != null
      ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
      : const LatLng(45.6770, -111.0429); // Bozeman fallback
  Set<Marker> get markers => _markers;
  Set<Polyline> get polylines => _polylines;
  bool get isSmartMode => _isSmartMode;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  Map<String, dynamic>? get routeInfo => _routeInfo;
  String get targetDistanceStr => _targetDistanceStr;
  // *** NEW: Getter for restaurant checkbox ***
  bool get endNearRestaurant => _endNearRestaurant;


  final TextEditingController distanceController = TextEditingController(text: "10");
  static const double _metersPerMile = 1609.34;
  static const int _maxRetriesSmartMode = 5;
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

  // *** NEW: Method to update restaurant preference ***
  void setEndNearRestaurant(bool value) {
    _endNearRestaurant = value;
    notifyListeners();
  }


  Future<void> _getCurrentLocation() async {
    // ... (Keep existing code, ensure it sets _currentPosition) ...
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
    _finalRestaurantLocation = null; // Reset restaurant location
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
      List<LatLng> finalWaypoints; // Waypoints used for Directions API
      Map<String, dynamic>? result;
      bool routeFound = false;
      int retries = 0;

      do {
        _markers.removeWhere((m) => m.markerId.value.startsWith('wp_') || m.markerId.value == 'restaurant');

        // *** Generate structured waypoints ***
        // Generate one less if we need to find a restaurant
        int pointsToGenerate = _endNearRestaurant ? 2 : 3;
        generatedWaypoints = _generateStructuredWaypoints(startPoint, targetDistMeters, _currentRadiusFactor, pointsToGenerate);

        // Clone for modification if needed
        finalWaypoints = List.from(generatedWaypoints);

        // *** Find restaurant if requested ***
        if (_endNearRestaurant && finalWaypoints.isNotEmpty) {
          LatLng lastWp = finalWaypoints.removeLast(); // Use location of last planned point as search center
          _finalRestaurantLocation = await _findNearbyRestaurant(lastWp);

          if (_finalRestaurantLocation != null) {
            finalWaypoints.add(_finalRestaurantLocation!); // Add restaurant location as final waypoint
            print("Restaurant found near last waypoint: $_finalRestaurantLocation");
          } else {
            // Couldn't find restaurant, add original last waypoint back
            finalWaypoints.add(lastWp);
            print("Could not find nearby restaurant, using original last waypoint.");
            // Optionally set an error message or warning here later
          }
        }

        // Get Directions using the final waypoint list
        result = await _getDirections(startPoint, startPoint, finalWaypoints);

        // --- (Rest of the retry logic based on distance - same as before) ---
        if (result != null) {
          final double actualDistanceMeters = result['distance_meters'];
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

      // --- (Result Processing - same as before, but pass finalWaypoints) ---
      if (routeFound && result != null) {
        // Pass the final list of waypoints used (might include restaurant)
        _processRouteResult(result, finalWaypoints);
        _animateToRouteBounds(result['bounds']);
      } else if (_isSmartMode && !routeFound) {
        String finalDistMsg = result != null ? "Last attempt distance: ${(result['distance_meters'] / _metersPerMile).toStringAsFixed(1)} mi." : "Could not generate a valid route.";
        _errorMessage = "Smart Loop failed after $retries attempts. $finalDistMsg Try a different distance or Simple Mode.";
        print(_errorMessage);
      } else if (result == null && _errorMessage == null) {
        _errorMessage = "Failed to get route. Check network or API keys.";
      }

    } catch (e) {
      _errorMessage = "Error generating loop: ${e.toString()}";
      print(_errorMessage);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // *** NEW: Structured Waypoint Generation ***
  List<LatLng> _generateStructuredWaypoints(LatLng start, double targetDistanceMeters, double radiusFactor, int numPoints) {
    final Random random = Random();
    final List<LatLng> waypoints = [];

    // Base radius calculation (remains a rough estimate)
    final double baseRadiusFraction = 0.35; // Slightly larger fraction for structured
    final double roughRadiusMeters = (targetDistanceMeters * baseRadiusFraction * radiusFactor) / 2;
    final double minRadius = 200.0; // Min 200m
    final double maxRadius = targetDistanceMeters * 0.8; // Max radius
    final double adjustedRadius = roughRadiusMeters.clamp(minRadius, maxRadius);

    print("Generating $numPoints structured waypoints with adjusted radius: ${adjustedRadius.toStringAsFixed(0)}m (Factor: ${radiusFactor.toStringAsFixed(2)})");

    const double earthRadius = 6371000.0;
    double initialBearing = random.nextDouble() * 2 * pi; // Random start direction

    // Define angular spread based on number of points
    // Try to spread points somewhat evenly in a large arc
    double totalArc = (pi * 1.5); // Spread points over ~270 degrees
    double angleIncrement = totalArc / (numPoints + 1);

    for (int i = 0; i < numPoints; i++) {
      // Calculate bearing for this point
      double currentBearing = initialBearing + (angleIncrement * (i + 1));
      // Vary distance slightly - maybe points further out are further along loop?
      double distance = adjustedRadius * (0.6 + (random.nextDouble() * 0.4)); // Skew slightly further out

      // Calculate LatLng based on bearing and distance
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

  // *** NEW: Find Nearby Restaurant using Places API ***
  Future<LatLng?> _findNearbyRestaurant(LatLng searchCenter) async {
    // Places API Nearby Search URL
    const String placesBaseUrl = "https://maps.googleapis.com/maps/api/place/nearbysearch/json";
    // Search within ~1.5km radius of the last planned point
    const double searchRadiusMeters = 1500;

    final Map<String, String> queryParams = {
      'location': '${searchCenter.latitude},${searchCenter.longitude}',
      'radius': searchRadiusMeters.toString(),
      'type': 'restaurant',
      'opennow': 'true', // Optional: prefer currently open places
      'key': googleApiKey, // Use the Places API key
      'rankby': 'prominence' // Rank by prominence within the radius
    };

    // Handle CORS for Places API if needed (same logic as Directions)
    const bool useCorsProxy = kIsWeb; // Use proxy only on web
    const String corsProxy = "https://cors-anywhere.herokuapp.com/"; // Example only

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
            // Pick the first result (most prominent)
            final place = data['results'][0];
            final location = place['geometry']['location'];
            return LatLng(location['lat'], location['lng']);
          } else {
            print("Places API: Zero results found for restaurants nearby.");
            _errorMessage = "No open restaurants found near the end of the loop."; // Set temporary error
            return null;
          }
        } else {
          _errorMessage = "Places API Error: ${data['status']} ${data['error_message'] ?? ''}";
          print(_errorMessage);
          return null;
        }
      } else {
        _errorMessage = "Places API HTTP Error: ${response.statusCode} ${response.reasonPhrase}";
        if (!useCorsProxy && (response.statusCode == 0 || response.statusCode == null)) {
          _errorMessage = "Places API Network Error (Code ${response.statusCode}): Potential CORS issue on web.";
        }
        print(_errorMessage);
        return null;
      }
    } catch (e) {
      _errorMessage = "Places API Network/Parsing Error: ${e.toString()}";
      if (!useCorsProxy && (e.toString().toLowerCase().contains('cors') || e.toString().toLowerCase().contains('xmlhttprequest'))) {
        _errorMessage = "Places API Network Error: Likely a CORS issue on web. Needs backend proxy.";
      }
      print(_errorMessage);
      return null;
    }
  }


  // *** MODIFIED: Remove optimize:true from waypoints parameter ***
  Future<Map<String, dynamic>?> _getDirections(
      LatLng origin, LatLng destination, List<LatLng> waypoints) async {

    // (CORS Proxy logic remains the same as previous answer - useCorsProxy flag)
    const bool useCorsProxy = kIsWeb; // Set based on target platform/strategy
    const String corsProxy = "https://cors-anywhere.herokuapp.com/";

    // *** Construct waypoints string WITHOUT optimize:true ***
    final String waypointsString = waypoints
        .map((wp) => 'via:${wp.latitude},${wp.longitude}')
        .join('|');

    final Map<String, String> queryParams = {
      'origin': '${origin.latitude},${origin.longitude}',
      'destination': '${destination.latitude},${destination.longitude}',
      // *** Only include waypoints if list is not empty ***
      if (waypointsString.isNotEmpty) 'waypoints': waypointsString,
      'mode': 'bicycling',
      'key': googleApiKey,
    };

    Uri url;
    if (useCorsProxy) {
      final String googleUrl = Uri.https('maps.googleapis.com', '/maps/api/directions/json', queryParams).toString();
      url = Uri.parse(corsProxy + googleUrl.substring(8));
    } else {
      url = Uri.https('maps.googleapis.com', '/maps/api/directions/json', queryParams);
    }

    print("Directions API URL (No Optimize): $url");

    try {
      // (Rest of the http.get and response handling is the same as previous answer)
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (useCorsProxy && response.body.contains("Missing required request header")) {
          _errorMessage = "CORS Proxy Error (Directions): Missing required headers.";
          print(_errorMessage);
          return null;
        }
        // ... (handle OK, ZERO_RESULTS, other statuses)
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
          if (data['status'] == 'ZERO_RESULTS') {
            _errorMessage = "Directions API Error: Could not find a bike route for the generated points.";
          }
          print(_errorMessage);
          return null;
        }

      } else {
        _errorMessage = "Directions HTTP Error: ${response.statusCode} ${response.reasonPhrase}";
        if (!useCorsProxy && (response.statusCode == 0 || response.statusCode == null)) {
          _errorMessage = "Directions Network Error (Code ${response.statusCode}): Potential CORS issue on web.";
        }
        print(_errorMessage);
        return null;
      }
    } catch (e) {
      _errorMessage = "Directions Network/Parsing Error: ${e.toString()}";
      if (!useCorsProxy && (e.toString().toLowerCase().contains('cors') || e.toString().toLowerCase().contains('xmlhttprequest'))) {
        _errorMessage = "Directions Network Error: Likely a CORS issue on web. Needs backend proxy.";
      }
      print(_errorMessage);
      return null;
    }
  }

  void _processRouteResult(Map<String, dynamic> result, List<LatLng> waypoints) {
    List<PointLatLng> decodedPoints = PolylinePoints().decodePolyline(result['polyline_points']);
    List<LatLng> polylineCoordinates = decodedPoints.map((p) => LatLng(p.latitude, p.longitude)).toList();

    Polyline routePolyline = Polyline(
      polylineId: const PolylineId('route'),
      color: Colors.blueAccent, // Changed color slightly
      points: polylineCoordinates,
      width: 5,
    );
    // Clear previous polylines before adding new one
    _polylines.clear();
    _polylines.add(routePolyline);

    _routeInfo = {
      'distance': (result['distance_meters'] / _metersPerMile).toStringAsFixed(1),
      'time': (result['duration_seconds'] / 60).toStringAsFixed(0),
      'turns': result['turns'],
    };

    // Add markers for the intermediate waypoints used (excluding start/end)
    for (int i = 0; i < waypoints.length; i++) {
      // Check if this waypoint is the restaurant location
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