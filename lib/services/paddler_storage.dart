import 'package:shared_preferences/shared_preferences.dart';

class PaddlerStorage {
  static const String _prefix = 'paddler_';
  static const String _calibratedPrefix = 'calibrated_';

  // Save MAC address to name mapping
  static Future<void> savePaddlerName(String macAddress, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$macAddress', name);
  }

  // Get name for MAC address
  static Future<String?> getPaddlerName(String macAddress) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefix$macAddress');
  }

  // Save calibrated status
  static Future<void> setCalibrated(String macAddress, bool calibrated) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_calibratedPrefix$macAddress', calibrated);
  }

  // Check if device is calibrated
  static Future<bool> isCalibrated(String macAddress) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_calibratedPrefix$macAddress') ?? false;
  }

  // Get all saved paddler mappings
  static Future<Map<String, String>> getAllPaddlers() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    final Map<String, String> paddlers = {};
    
    for (var key in keys) {
      if (key.startsWith(_prefix)) {
        final macAddress = key.substring(_prefix.length);
        final name = prefs.getString(key);
        if (name != null) {
          paddlers[macAddress] = name;
        }
      }
    }
    
    return paddlers;
  }

  // Remove a paddler mapping
  static Future<void> removePaddler(String macAddress) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$macAddress');
    await prefs.remove('$_calibratedPrefix$macAddress');
  }
}

