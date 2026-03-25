import 'paddler.dart';

class Session {
  final String id;
  final String name;
  final DateTime dateTime;
  final List<Paddler> paddlers;
  final Duration duration;

  Session({
    required this.id,
    required this.name,
    required this.dateTime,
    required this.paddlers,
    required this.duration,
  });
}

