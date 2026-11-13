import 'dart:io' show Platform;

/// Reads an environment variable.
String? readEnv(String name) => Platform.environment[name];
