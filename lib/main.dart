// lib/main.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'map_state.dart';
import 'home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (context) => MapState(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BikeLoop',
      theme: ThemeData(
        primarySwatch: Colors.deepPurple, // Match AppBar color
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple), // Use color scheme
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}