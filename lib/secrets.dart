// lib/secrets.dart

/// Google API key injected at build time.
/// Pass it via: --dart-define=GOOGLE_API_KEY=your_real_key
const String googleApiKey = String.fromEnvironment('GOOGLE_API_KEY');