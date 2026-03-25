import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/home_screen.dart';
import 'providers/paddler_provider.dart';
import 'providers/ble_provider.dart';

void main() {
  runApp(const DragonBoatTrackerApp());
}

class DragonBoatTrackerApp extends StatelessWidget {
  const DragonBoatTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: BLEProvider()),
        ChangeNotifierProvider(
          create: (_) => PaddlerProvider()..syncPaddlersFromConnectedDevices(),
        ),
      ],
      child: MaterialApp(
        title: 'Dragon Boat Tracker',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.light,
          ),
        ),
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
