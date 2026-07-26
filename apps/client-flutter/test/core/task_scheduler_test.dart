import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/task_scheduler.dart';

void main() {
  test('does not overlap invocations of the same periodic task', () async {
    final scheduler = PeriodicTaskScheduler();
    final firstRun = Completer<void>();
    var invocations = 0;

    scheduler.schedule(
      'sync',
      interval: const Duration(milliseconds: 5),
      runImmediately: true,
      callback: () async {
        invocations += 1;
        if (invocations == 1) {
          await firstRun.future;
        }
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(invocations, 1);

    firstRun.complete();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(invocations, greaterThan(1));

    scheduler.dispose();
  });

  test('pauses foreground work while backgrounded', () async {
    final scheduler = PeriodicTaskScheduler()..setBackgrounded(true);
    var foregroundRuns = 0;
    var backgroundRuns = 0;

    scheduler.schedule(
      'foreground',
      interval: const Duration(milliseconds: 5),
      runImmediately: true,
      callback: () => foregroundRuns += 1,
    );
    scheduler.schedule(
      'background',
      interval: const Duration(milliseconds: 5),
      runImmediately: true,
      runInBackground: true,
      callback: () => backgroundRuns += 1,
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(foregroundRuns, 0);
    expect(backgroundRuns, greaterThan(0));

    scheduler.setBackgrounded(false);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(foregroundRuns, greaterThan(0));

    scheduler.dispose();
  });

  test('replacing and cancelling tasks disposes their timers', () async {
    final scheduler = PeriodicTaskScheduler();
    var oldRuns = 0;
    var replacementRuns = 0;

    scheduler.schedule(
      'refresh',
      interval: const Duration(milliseconds: 5),
      callback: () => oldRuns += 1,
    );
    scheduler.schedule(
      'refresh',
      interval: const Duration(milliseconds: 5),
      callback: () => replacementRuns += 1,
    );
    await Future<void>.delayed(const Duration(milliseconds: 16));

    expect(oldRuns, 0);
    expect(replacementRuns, greaterThan(0));
    scheduler.cancel('refresh');
    final runsAfterCancel = replacementRuns;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(replacementRuns, runsAfterCancel);

    scheduler.dispose();
  });
}
