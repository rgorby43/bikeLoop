import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'map_state.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isPanelVisible = true;
  bool _allowPanelHide = true;

  @override
  Widget build(BuildContext context) {
    final mapState = Provider.of<MapState>(context);
    const double panelHeight = 400.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BikeLoop Generator'),
        backgroundColor: Colors.blueGrey,
        foregroundColor: Colors.white,
      ),
      // Change 2: Move the FloatingActionButton to the left
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: !_isPanelVisible ? FloatingActionButton(
        onPressed: () {
          setState(() {
            _isPanelVisible = true;
          });
        },
        backgroundColor: Colors.blueGrey,
        foregroundColor: Colors.white,
        tooltip: 'Show Controls',
        child: const Icon(Icons.keyboard_arrow_up),
      ) : null,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Stack(
          children: [
            GoogleMap(
              initialCameraPosition: CameraPosition(
                target: mapState.initialCameraPosition ?? const LatLng(38.5358, -105.9910),
                zoom: 12.0,
              ),
              onMapCreated: mapState.onMapCreated,
              onLongPress: mapState.setCustomStartLocation,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              markers: mapState.markers,
              polylines: mapState.polylines,
              padding: EdgeInsets.only(bottom: _isPanelVisible ? panelHeight - 50 : 0),
              mapType: MapType.normal,
              // Change 3: Update onCameraMoveStarted with the new logic
              onCameraMoveStarted: () {
                FocusScope.of(context).unfocus();
                // Only hide the panel if it's visible AND allowed to hide
                if (_isPanelVisible && _allowPanelHide) {
                  setState(() {
                    _isPanelVisible = false;
                  });
                }
              },
              // Change 4: Add onCameraIdle to re-enable panel hiding
              onCameraIdle: () {
                // After any camera animation finishes, allow the panel to be hidden by the user again.
                if (!_allowPanelHide) {
                  setState(() {
                    _allowPanelHide = true;
                  });
                }
              },
            ),
            Positioned(
              bottom: 750, // Adjust vertical position as needed
              right: 15,  // Adjust horizontal position as needed
              child: FloatingActionButton(
                onPressed: mapState.animateToUser,
                backgroundColor: Colors.blueGrey,
                foregroundColor: Colors.white,
                tooltip: 'My Location',
                child: const Icon(Icons.my_location),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              left: 0,
              right: 0,
              bottom: _isPanelVisible ? 0 : -panelHeight,
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
                          textStyle: const TextStyle(fontSize: 16)),
                      // Change 5: Update the onPressed logic
                      onPressed: () {
                        setState(() {
                          // Ensure panel is visible to show results
                          _isPanelVisible = true;
                          // Prevent panel from hiding during the coming animation
                          _allowPanelHide = false;
                        });
                        mapState.generateLoop();
                      },
                    ),
                    const SizedBox(height: 5),
                    if (mapState.errorMessage != null && !mapState.isLoading)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(
                          mapState.errorMessage!,
                          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
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
      ),
    );
  }

  Widget _buildCustomLocationCard(BuildContext context, MapState mapState) {
    // ... same as before
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.blue.shade200)),
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

  Widget _buildSummaryCard(
      BuildContext context, Map<String, dynamic> routeInfo) {
    // ... same as before
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
                _summaryItem(Icons.route_outlined, '${routeInfo['distance']} mi',
                    'Distance'),
                _summaryItem(Icons.timer_outlined, '${routeInfo['time']} min',
                    'Est. Time'),
              ],
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.navigation_outlined),
              label: const Text('Start Navigation'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 40)),
              onPressed: mapState.startNavigation,
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryItem(IconData icon, String value, String label) {
    // ... same as before
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.black, size: 28),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}