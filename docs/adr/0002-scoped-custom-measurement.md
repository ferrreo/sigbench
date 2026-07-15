# Scoped custom measurement

Custom benchmarks that need setup and teardown use `Bencher.iterCustomScoped` and place exactly
one `MeasurementScope.start`/`stop` pair around measured work. Bencher injects selected counter
operations into its timing loops; sample collection does not wrap the whole benchmark case.
Legacy `iterCustom` and `finishCustom` keep wall-clock behavior, but cycle and perf measurements
reject them because their returned nanoseconds cannot represent the selected counter. Active
scopes close on callback errors, while the original callback error remains the result. This adds
one explicit boundary API and prevents setup cost from silently contaminating counter samples.
Failed counter stops return their original error without invoking the counter stop twice.
