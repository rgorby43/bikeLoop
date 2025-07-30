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
              target: mapState.initialCameraPosition ?? const LatLng(38.5358, -105.9910),
              zoom: 12.0,
            ),
            onMapCreated: mapState.onMapCreated,
            onLongPress: mapState.setCustomStartLocation,
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
                  if (mapState.customStartController.text.isNotEmpty)
                    _buildCustomLocationCard(context, mapState),
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
                    _buildSummaryCard(context, mapState.routeInfo!),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomLocationCard(BuildContext context, MapState mapState) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue.shade200)
      ),
      child: Row(
        children: [
          Icon(Icons.push_pin, color: Colors.blue.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: mapState.customStartController,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'Custom Start Location',
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Use My Location',
            onPressed: mapState.clearCustomStartLocation,
            visualDensity: VisualDensity.compact,
          )
        ],
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context, Map<String, dynamic> routeInfo) {
    final mapState = Provider.of<MapState>(context, listen: false);

    return Card(
      margin: const EdgeInsets.only(top: 15.0),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _summaryItem(Icons.route_outlined, '${routeInfo['distance']} mi', 'Distance'),
                _summaryItem(Icons.timer_outlined, '${routeInfo['time']} min', 'Est. Time'),
              ],
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.navigation_outlined),
              label: const Text('Start Navigation'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 40)
              ),
              onPressed: mapState.startNavigation,
            ),
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