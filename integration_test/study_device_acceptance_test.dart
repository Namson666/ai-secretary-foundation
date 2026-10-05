import 'study_runtime_test.dart' as runtime;
import 'study_app_journey_test.dart' as journeys;

/// One native install runs both production-provider and native SQLite journeys.
void main() {
  runtime.main();
  journeys.main();
}
