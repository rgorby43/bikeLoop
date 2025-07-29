// lib/home_screen.dart
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'map_state.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mapState = Provider.of<MapState>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('BikeLoop Generator'),
        backgroundColor: Colors.blueGrey,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: mapState.initialCameraPosition ?? const LatLng(38.5358, -105.9910), // Salida, CO fallback
              zoom: 12.0,
            ),
            onMapCreated: mapState.onMapCreated,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            markers: mapState.markers,
            polylines: mapState.polylines,
            padding: const EdgeInsets.only(bottom: 250),
            mapType: MapType.normal,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.95),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18.0),
                  topRight: Radius.circular(18.0),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 8.0,
                    spreadRadius: 1.0,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: mapState.distanceController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Target Distance (miles)',
                      hintText: 'e.g., 15',
                      border: OutlineInputBorder(),
                      suffixText: 'miles',
                      prefixIcon: Icon(Icons.map),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Smart Loop (match distance)', style: TextStyle(fontSize: 16)),
                      Switch(
                        value: mapState.isSmartMode,
                        onChanged: mapState.isLoading ? null : (value) {
                          mapState.setSmartMode(value);
                        },
                      ),
                    ],
                  ),
                  CheckboxListTile(
                    title: const Text("End near a restaurant?"),
                    value: mapState.endNearRestaurant,
                    onChanged: mapState.isLoading ? null : (bool? value) {
                      mapState.setEndNearRestaurant(value ?? false);
                    },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 10),
                  mapState.isLoading
                      ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10.0),
                    child: Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 8),
                        Text("Generating Route...")
                      ],
                    ),
                  )
                      : ElevatedButton.icon(
                    icon: const Icon(Icons.directions_bike),
                    label: const Text('Generate Loop'),
                    style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        backgroundColor: Colors.blueGrey,
                        foregroundColor: Colors.white,
                        textStyle: const TextStyle(fontSize: 16)
                    ),
                    onPressed: mapState.generateLoop,
                  ),
                  const SizedBox(height: 5),
                  if (mapState.errorMessage != null && !mapState.isLoading)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text(
                        mapState.errorMessage!,
                        style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (mapState.routeInfo != null && !mapState.isLoading)
                    _buildSummaryCard(mapState.routeInfo!),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(Map<String, dynamic> routeInfo) {
    return Card(
      margin: const EdgeInsets.only(top: 15.0),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _summaryItem(Icons.route_outlined, '${routeInfo['distance']} mi', 'Distance'),
            _summaryItem(Icons.timer_outlined, '${routeInfo['time']} min', 'Est. Time'),
            // --- UPDATED: Removed the 'Turns' item ---
          ],
        ),
      ),
    );
  }

  Widget _summaryItem(IconData icon, String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.black, size: 28),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}