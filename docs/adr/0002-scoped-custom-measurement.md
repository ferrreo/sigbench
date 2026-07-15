# Scoped custom measurement

Custom benchmarks that need setup and teardown use `Bencher.iterCustomScoped` and place exactly
one `MeasurementScope.start`/`stop` pair around measured work. Bencher injects selected counter
operations into its timing loops; sample collection does not wrap the whole benchmark case.
Legacy `iterCustom` and `finishCustom` keep wall-clock behavior, but cycle and perf measurements
reject them because their returned nanoseconds cannot represent the selected counter. Active
scopes close on callback errors, while the original callback error remains the result. This adds
one explicit boundary API and prevents setup cost from silently contaminating counter samples.
Failed counter stops return their original error without invoking the counter stop twice.
Scopes also expose `includeThread(std.Thread.Id)` during setup. Measurement drivers may provide
an inclusion hook; absent hooks are no-ops for wall-clock and serialized TSC measurements. Hook
errors persist even when caught, and calling the method after `start` invalidates the scope.
Each scope also invokes an optional driver cleanup hook exactly once. Cleanup runs after success,
callback failure, and protocol failure, including failures before `start`, without replacing an
earlier driver, protocol, or callback result. Retained driver errors take precedence over later
protocol or callback errors; driver-end cleanup errors do not replace an original callback failure.
Batch routines that need explicit resource release use `Bencher.iterBatchWithTeardown` instead.
It runs teardown once after every successful setup and outside measurement, including when
measurement start or end fails; its callbacks remain infallible like `iterBatch`.
