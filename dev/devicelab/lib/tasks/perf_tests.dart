// Copyright (c) 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show JSON;

import '../framework/adb.dart';
import '../framework/framework.dart';
import '../framework/utils.dart';

TaskFunction createComplexLayoutScrollPerfTest() {
  return new PerfTest(
    '${flutterDirectory.path}/dev/benchmarks/complex_layout',
    'test_driver/scroll_perf.dart',
    'complex_layout_scroll_perf',
  );
}

TaskFunction createComplexLayoutScrollMemoryTest() {
  return new MemoryTest(
    '${flutterDirectory.path}/dev/benchmarks/complex_layout',
    'com.yourcompany.complexLayout',
    testTarget: 'test_driver/scroll_perf.dart',
  );
}

TaskFunction createFlutterGalleryStartupTest() {
  return new StartupTest(
    '${flutterDirectory.path}/examples/flutter_gallery',
  );
}

TaskFunction createComplexLayoutStartupTest() {
  return new StartupTest(
    '${flutterDirectory.path}/dev/benchmarks/complex_layout',
  );
}

TaskFunction createFlutterGalleryBuildTest() {
  return new BuildTest('${flutterDirectory.path}/examples/flutter_gallery');
}

TaskFunction createComplexLayoutBuildTest() {
  return new BuildTest('${flutterDirectory.path}/dev/benchmarks/complex_layout');
}

TaskFunction createHelloWorldMemoryTest() {
  return new MemoryTest(
    '${flutterDirectory.path}/examples/hello_world',
    'io.flutter.examples.HelloWorld',
  );
}

TaskFunction createGalleryNavigationMemoryTest() {
  return new MemoryTest(
    '${flutterDirectory.path}/examples/flutter_gallery',
    'io.flutter.examples.gallery',
    testTarget: 'test_driver/memory_nav.dart',
  );
}

TaskFunction createGalleryBackButtonMemoryTest() {
  return new AndroidBackButtonMemoryTest(
    '${flutterDirectory.path}/examples/flutter_gallery',
    'io.flutter.examples.gallery',
  );
}

/// Measure application startup performance.
class StartupTest {
  static const Duration _startupTimeout = const Duration(minutes: 2);

  StartupTest(this.testDirectory);

  final String testDirectory;

  Future<TaskResult> call() async {
    return await inDirectory(testDirectory, () async {
      String deviceId = (await devices.workingDevice).deviceId;
      await flutter('packages', options: <String>['get']);

      if (deviceOperatingSystem == DeviceOperatingSystem.ios) {
        // This causes an Xcode project to be created.
        await flutter('build', options: <String>['ios', '--profile']);
      }

      await flutter('run', options: <String>[
        '--profile',
        '--trace-startup',
        '-d',
        deviceId,
      ]).timeout(_startupTimeout);
      Map<String, dynamic> data = JSON.decode(file('$testDirectory/build/start_up_info.json').readAsStringSync());
      return new TaskResult.success(data, benchmarkScoreKeys: <String>[
        'timeToFirstFrameMicros',
      ]);
    });
  }
}

/// Measures application runtime performance, specifically per-frame
/// performance.
class PerfTest {

  PerfTest(this.testDirectory, this.testTarget, this.timelineFileName);

  final String testDirectory;
  final String testTarget;
  final String timelineFileName;

  Future<TaskResult> call() {
    return inDirectory(testDirectory, () async {
      Device device = await devices.workingDevice;
      await device.unlock();
      String deviceId = device.deviceId;
      await flutter('packages', options: <String>['get']);

      if (deviceOperatingSystem == DeviceOperatingSystem.ios) {
        // This causes an Xcode project to be created.
        await flutter('build', options: <String>['ios', '--profile']);
      }

      await flutter('drive', options: <String>[
        '-v',
        '--profile',
        '--trace-startup', // Enables "endless" timeline event buffering.
        '-t',
        testTarget,
        '-d',
        deviceId,
      ]);
      Map<String, dynamic> data = JSON.decode(file('$testDirectory/build/$timelineFileName.timeline_summary.json').readAsStringSync());

      if (data['frame_count'] < 5) {
        return new TaskResult.failure(
          'Timeline contains too few frames: ${data['frame_count']}. Possibly '
          'trace events are not being captured.',
        );
      }

      return new TaskResult.success(data, benchmarkScoreKeys: <String>[
        'average_frame_build_time_millis',
        'worst_frame_build_time_millis',
        'missed_frame_build_budget_count',
        'average_frame_rasterizer_time_millis',
        'worst_frame_rasterizer_time_millis',
        'missed_frame_rasterizer_budget_count',
      ]);
    });
  }
}

class BuildTest {

  BuildTest(this.testDirectory);

  final String testDirectory;

  Future<TaskResult> call() async {
    return await inDirectory(testDirectory, () async {
      Device device = await devices.workingDevice;
      await device.unlock();
      await flutter('packages', options: <String>['get']);

      Stopwatch watch = new Stopwatch()..start();
      await flutter('build', options: <String>[
        'aot',
        '--profile',
        '--no-pub',
        '--target-platform', 'android-arm'  // Generate blobs instead of assembly.
      ]);
      watch.stop();

      int vmisolateSize = file("$testDirectory/build/aot/snapshot_aot_vmisolate").lengthSync();
      int isolateSize = file("$testDirectory/build/aot/snapshot_aot_isolate").lengthSync();
      int instructionsSize = file("$testDirectory/build/aot/snapshot_aot_instr").lengthSync();
      int rodataSize = file("$testDirectory/build/aot/snapshot_aot_rodata").lengthSync();
      int totalSize = vmisolateSize + isolateSize + instructionsSize + rodataSize;

      Map<String, dynamic> data = <String, dynamic>{
        'aot_snapshot_build_millis': watch.elapsedMilliseconds,
        'aot_snapshot_size_vmisolate': vmisolateSize,
        'aot_snapshot_size_isolate': isolateSize,
        'aot_snapshot_size_instructions': instructionsSize,
        'aot_snapshot_size_rodata': rodataSize,
        'aot_snapshot_size_total': totalSize,
      };
      return new TaskResult.success(data, benchmarkScoreKeys: <String>[
        'aot_snapshot_build_millis',
        'aot_snapshot_size_vmisolate',
        'aot_snapshot_size_isolate',
        'aot_snapshot_size_instructions',
        'aot_snapshot_size_rodata',
        'aot_snapshot_size_total',
      ]);
    });
  }
}

/// Measure application memory usage.
class MemoryTest {
  MemoryTest(this.testDirectory, this.packageName, { this.testTarget });

  final String testDirectory;
  final String packageName;

  /// Path to a flutter driver script that will run after starting the app.
  ///
  /// If not specified, then the test will start the app, gather statistics, and then exit.
  final String testTarget;

  Future<TaskResult> call() {
    return inDirectory(testDirectory, () async {
      Device device = await devices.workingDevice;
      await device.unlock();
      String deviceId = device.deviceId;
      await flutter('packages', options: <String>['get']);

      if (deviceOperatingSystem == DeviceOperatingSystem.ios) {
        // This causes an Xcode project to be created.
        await flutter('build', options: <String>['ios', '--profile']);
      }

      int debugPort = await findAvailablePort();

      List<String> runOptions = <String>[
        '-v',
        '--profile',
        '--trace-startup', // wait for the first frame to render
        '-d',
        deviceId,
        '--debug-port',
        debugPort.toString(),
      ];
      if (testTarget != null)
        runOptions.addAll(<String>['-t', testTarget]);
      await flutter('run', options: runOptions);

      Map<String, dynamic> startData = await device.getMemoryStats(packageName);

      Map<String, dynamic> data = <String, dynamic>{
         'start_total_kb': startData['total_kb'],
      };

      if (testTarget != null) {
        await flutter('drive', options: <String>[
          '-v',
          '-t',
          testTarget,
          '-d',
          deviceId,
          '--use-existing-app',
        ], env: <String, String> {
          'VM_SERVICE_URL': 'http://localhost:$debugPort'
        });

        Map<String, dynamic> endData = await device.getMemoryStats(packageName);
        data['end_total_kb'] = endData['total_kb'];
        data['diff_total_kb'] = endData['total_kb'] - startData['total_kb'];
      }

      await device.stop(packageName);

      return new TaskResult.success(data, benchmarkScoreKeys: data.keys.toList());
    });
  }
}

/// Measure application memory usage after pausing and resuming the app
/// with the Android back button.
class AndroidBackButtonMemoryTest {
  final String testDirectory;
  final String packageName;

  AndroidBackButtonMemoryTest(this.testDirectory, this.packageName);

  Future<TaskResult> call() {
    return inDirectory(testDirectory, () async {
      if (deviceOperatingSystem != DeviceOperatingSystem.android) {
        throw 'This test is only supported on Android';
      }

      AndroidDevice device = await devices.workingDevice;
      await device.unlock();
      String deviceId = device.deviceId;
      await flutter('packages', options: <String>['get']);

      await flutter('run', options: <String>[
        '-v',
        '--profile',
        '--trace-startup', // wait for the first frame to render
        '-d',
        deviceId,
      ]);

      Map<String, dynamic> startData = await device.getMemoryStats(packageName);

      Map<String, dynamic> data = <String, dynamic>{
         'start_total_kb': startData['total_kb'],
      };

      // Perform a series of back button suspend and resume cycles.
      for (int i = 0; i < 10; i++) {
        device.shellExec('input', <String>['keyevent', 'KEYCODE_BACK']);
        await new Future<Null>.delayed(new Duration(milliseconds: 1000));
        device.shellExec('am', <String>['start', '-n', 'io.flutter.examples.gallery/org.domokit.sky.shell.SkyActivity']);
        await new Future<Null>.delayed(new Duration(milliseconds: 1000));
      }

      Map<String, dynamic> endData = await device.getMemoryStats(packageName);
      data['end_total_kb'] = endData['total_kb'];
      data['diff_total_kb'] = endData['total_kb'] - startData['total_kb'];

      await device.stop(packageName);

      return new TaskResult.success(data, benchmarkScoreKeys: data.keys.toList());
    });
  }
}
