// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../android/android_sdk.dart';
import '../application_package.dart';
import '../base/os.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../base/process_manager.dart';
import '../build_info.dart';
import '../commands/build_apk.dart';
import '../device.dart';
import '../globals.dart';
import '../protocol_discovery.dart';

import 'adb.dart';
import 'android.dart';
import 'android_sdk.dart';

const String _defaultAdbPath = 'adb';

class AndroidDevices extends PollingDeviceDiscovery {
  AndroidDevices() : super('AndroidDevices');

  @override
  bool get supportsPlatform => true;

  @override
  List<Device> pollingGetDevices() => getAdbDevices();
}

class AndroidDevice extends Device {
  AndroidDevice(
    String id, {
    this.productID,
    this.modelID,
    this.deviceCodeName
  }) : super(id);

  final String productID;
  final String modelID;
  final String deviceCodeName;

  Map<String, String> _properties;
  bool _isLocalEmulator;
  TargetPlatform _platform;

  String _getProperty(String name) {
    if (_properties == null) {
      _properties = <String, String>{};

      List<String> propCommand = adbCommandForDevice(<String>['shell', 'getprop']);
      printTrace(propCommand.join(' '));

      try {
        // We pass an encoding of LATIN1 so that we don't try and interpret the
        // `adb shell getprop` result as UTF8.
        ProcessResult result = processManager.runSync(
          propCommand.first,
          propCommand.sublist(1),
          stdoutEncoding: LATIN1
        );
        if (result.exitCode == 0) {
          _properties = parseAdbDeviceProperties(result.stdout);
        } else {
          printError('Error retrieving device properties for $name.');
        }
      } catch (error) {
        printError('Error retrieving device properties for $name: $error');
      }
    }

    return _properties[name];
  }

  @override
  bool get isLocalEmulator {
    if (_isLocalEmulator == null) {
      String characteristics = _getProperty('ro.build.characteristics');
      _isLocalEmulator = characteristics != null && characteristics.contains('emulator');
    }
    return _isLocalEmulator;
  }

  @override
  TargetPlatform get platform {
    if (_platform == null) {
      // http://developer.android.com/ndk/guides/abis.html (x86, armeabi-v7a, ...)
      switch (_getProperty('ro.product.cpu.abi')) {
        case 'x86_64':
          _platform = TargetPlatform.android_x64;
          break;
        case 'x86':
          _platform = TargetPlatform.android_x86;
          break;
        default:
          _platform = TargetPlatform.android_arm;
          break;
      }
    }

    return _platform;
  }

  @override
  String get sdkNameAndVersion => 'Android $_sdkVersion (API $_apiVersion)';

  String get _sdkVersion => _getProperty('ro.build.version.release');

  String get _apiVersion => _getProperty('ro.build.version.sdk');

  _AdbLogReader _logReader;
  _AndroidDevicePortForwarder _portForwarder;

  List<String> adbCommandForDevice(List<String> args) {
    return <String>[getAdbPath(androidSdk), '-s', id]..addAll(args);
  }

  bool _isValidAdbVersion(String adbVersion) {
    // Sample output: 'Android Debug Bridge version 1.0.31'
    Match versionFields = new RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(adbVersion);
    if (versionFields != null) {
      int majorVersion = int.parse(versionFields[1]);
      int minorVersion = int.parse(versionFields[2]);
      int patchVersion = int.parse(versionFields[3]);
      if (majorVersion > 1) {
        return true;
      }
      if (majorVersion == 1 && minorVersion > 0) {
        return true;
      }
      if (majorVersion == 1 && minorVersion == 0 && patchVersion >= 32) {
        return true;
      }
      return false;
    }
    printError(
        'Unrecognized adb version string $adbVersion. Skipping version check.');
    return true;
  }

  bool _checkForSupportedAdbVersion() {
    if (androidSdk == null)
      return false;

    try {
      String adbVersion = runCheckedSync(<String>[getAdbPath(androidSdk), 'version']);
      if (_isValidAdbVersion(adbVersion))
        return true;
      printError('The ADB at "${getAdbPath(androidSdk)}" is too old; please install version 1.0.32 or later.');
    } catch (error, trace) {
      printError('Error running ADB: $error', trace);
    }

    return false;
  }

  bool _checkForSupportedAndroidVersion() {
    try {
      // If the server is automatically restarted, then we get irrelevant
      // output lines like this, which we want to ignore:
      //   adb server is out of date.  killing..
      //   * daemon started successfully *
      runCheckedSync(<String>[getAdbPath(androidSdk), 'start-server']);

      // Sample output: '22'
      String sdkVersion = _getProperty('ro.build.version.sdk');

      int sdkVersionParsed = int.parse(sdkVersion, onError: (String source) => null);
      if (sdkVersionParsed == null) {
        printError('Unexpected response from getprop: "$sdkVersion"');
        return false;
      }

      if (sdkVersionParsed < minApiLevel) {
        printError(
          'The Android version ($sdkVersion) on the target device is too old. Please '
          'use a $minVersionName (version $minApiLevel / $minVersionText) device or later.');
        return false;
      }

      return true;
    } catch (e) {
      printError('Unexpected failure from adb: $e');
      return false;
    }
  }

  String _getDeviceSha1Path(ApplicationPackage app) {
    return '/data/local/tmp/sky.${app.id}.sha1';
  }

  String _getDeviceApkSha1(ApplicationPackage app) {
    return runCheckedSync(adbCommandForDevice(<String>['shell', 'cat', _getDeviceSha1Path(app)]));
  }

  String _getSourceSha1(ApplicationPackage app) {
    AndroidApk apk = app;
    File shaFile = new File('${apk.apkPath}.sha1');
    return shaFile.existsSync() ? shaFile.readAsStringSync() : '';
  }

  @override
  String get name => modelID;

  @override
  bool isAppInstalled(ApplicationPackage app) {
    // This call takes 400ms - 600ms.
    String listOut = runCheckedSync(adbCommandForDevice(<String>['shell', 'pm', 'list', 'packages', app.id]));
    if (!LineSplitter.split(listOut).contains("package:${app.id}"))
      return false;

    // Check the application SHA.
    return _getDeviceApkSha1(app) == _getSourceSha1(app);
  }

  @override
  bool installApp(ApplicationPackage app) {
    AndroidApk apk = app;
    if (!FileSystemEntity.isFileSync(apk.apkPath)) {
      printError('"${apk.apkPath}" does not exist.');
      return false;
    }

    if (!_checkForSupportedAdbVersion() || !_checkForSupportedAndroidVersion())
      return false;

    Status status = logger.startProgress('Installing ${apk.apkPath}...');
    String installOut = runCheckedSync(adbCommandForDevice(<String>['install', '-r', apk.apkPath]));
    status.stop();
    RegExp failureExp = new RegExp(r'^Failure.*$', multiLine: true);
    String failure = failureExp.stringMatch(installOut);
    if (failure != null) {
      printError('Package install error: $failure');
      return false;
    }

    runCheckedSync(adbCommandForDevice(<String>['shell', 'echo', '-n', _getSourceSha1(app), '>', _getDeviceSha1Path(app)]));
    return true;
  }

  @override
  bool uninstallApp(ApplicationPackage app) {
    if (!_checkForSupportedAdbVersion() || !_checkForSupportedAndroidVersion())
      return false;

    String uninstallOut = runCheckedSync(adbCommandForDevice(<String>['uninstall', app.id]));
    RegExp failureExp = new RegExp(r'^Failure.*$', multiLine: true);
    String failure = failureExp.stringMatch(uninstallOut);
    if (failure != null) {
      printError('Package uninstall error: $failure');
      return false;
    }

    return true;
  }

  @override
  Future<LaunchResult> startApp(
    ApplicationPackage package,
    BuildMode mode, {
    String mainPath,
    String route,
    DebuggingOptions debuggingOptions,
    Map<String, dynamic> platformArgs,
    bool prebuiltApplication: false
  }) async {
    if (!_checkForSupportedAdbVersion() || !_checkForSupportedAndroidVersion())
      return new LaunchResult.failed();

    printTrace("Stopping app '${package.name}' on $name.");
    await stopApp(package);

    if (!prebuiltApplication) {
      printTrace('Building APK');
      await buildApk(platform,
          target: mainPath,
          buildMode: debuggingOptions.buildMode
      );
    }

    if (isAppInstalled(package)) {
      printStatus('Uninstalling old version...');
      if (!uninstallApp(package))
        printError('Warning: uninstalling old version failed');
    }

    printTrace('Installing APK.');
    if (!installApp(package)) {
      printTrace('Error: Failed to install APK.');
      return new LaunchResult.failed();
    }

    final bool traceStartup = platformArgs['trace-startup'] ?? false;
    final AndroidApk apk = package;
    printTrace('$this startApp');

    ProtocolDiscovery observatoryDiscovery;
    ProtocolDiscovery diagnosticDiscovery;

    if (debuggingOptions.debuggingEnabled) {
      // TODO(devoncarew): Remember the forwarding information (so we can later remove the
      // port forwarding).
      observatoryDiscovery = new ProtocolDiscovery.observatory(
        getLogReader(), portForwarder: portForwarder, hostPort: debuggingOptions.observatoryPort);
      diagnosticDiscovery = new ProtocolDiscovery.diagnosticService(
        getLogReader(), portForwarder: portForwarder, hostPort: debuggingOptions.diagnosticPort);
    }

    List<String> cmd;

    cmd = adbCommandForDevice(<String>[
      'shell', 'am', 'start',
      '-a', 'android.intent.action.RUN',
      '-f', '0x20000000',  // FLAG_ACTIVITY_SINGLE_TOP
      '--ez', 'enable-background-compilation', 'true',
      '--ez', 'enable-dart-profiling', 'true',
    ]);

    if (traceStartup)
      cmd.addAll(<String>['--ez', 'trace-startup', 'true']);
    if (route != null)
      cmd.addAll(<String>['--es', 'route', route]);
    if (debuggingOptions.debuggingEnabled) {
      if (debuggingOptions.buildMode == BuildMode.debug)
        cmd.addAll(<String>['--ez', 'enable-checked-mode', 'true']);
      if (debuggingOptions.startPaused)
        cmd.addAll(<String>['--ez', 'start-paused', 'true']);
    }
    cmd.add(apk.launchActivity);
    String result = runCheckedSync(cmd);
    // This invocation returns 0 even when it fails.
    if (result.contains('Error: ')) {
      printError(result.trim());
      return new LaunchResult.failed();
    }

    if (!debuggingOptions.debuggingEnabled) {
      return new LaunchResult.succeeded();
    }

    // Wait for the service protocol port here. This will complete once the
    // device has printed "Observatory is listening on...".
    printTrace('Waiting for observatory port to be available...');

    // TODO(danrubel) Waiting for observatory and diagnostic services
    // can be made common across all devices.
    try {
      Uri observatoryUri, diagnosticUri;

      if (debuggingOptions.buildMode == BuildMode.debug) {
        List<Uri> deviceUris = await Future.wait(
            <Future<Uri>>[observatoryDiscovery.nextUri(), diagnosticDiscovery.nextUri()]
        );
        observatoryUri = deviceUris[0];
        diagnosticUri = deviceUris[1];
      } else if (debuggingOptions.buildMode == BuildMode.profile) {
        observatoryUri = await observatoryDiscovery.nextUri();
      }

      return new LaunchResult.succeeded(
          observatoryUri: observatoryUri,
          diagnosticUri: diagnosticUri,
      );
    } catch (error) {
      printError('Error waiting for a debug connection: $error');
      return new LaunchResult.failed();
    } finally {
      observatoryDiscovery.cancel();
      diagnosticDiscovery.cancel();
    }
  }

  @override
  bool get supportsHotMode => true;

  @override
  Future<bool> stopApp(ApplicationPackage app) {
    List<String> command = adbCommandForDevice(<String>['shell', 'am', 'force-stop', app.id]);
    return runCommandAndStreamOutput(command).then((int exitCode) => exitCode == 0);
  }

  @override
  void clearLogs() {
    runSync(adbCommandForDevice(<String>['logcat', '-c']));
  }

  @override
  DeviceLogReader getLogReader({ApplicationPackage app}) {
    // The Android log reader isn't app-specific.
    _logReader ??= new _AdbLogReader(this);
    return _logReader;
  }

  @override
  DevicePortForwarder get portForwarder {
    if (_portForwarder == null)
      _portForwarder = new _AndroidDevicePortForwarder(this);

    return _portForwarder;
  }

  static RegExp _timeRegExp = new RegExp(r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}', multiLine: true);

  /// Return the most recent timestamp in the Android log or `null` if there is
  /// no available timestamp. The format can be passed to logcat's -T option.
  String get lastLogcatTimestamp {
    String output = runCheckedSync(adbCommandForDevice(<String>[
      'logcat', '-v', 'time', '-t', '1'
    ]));

    Match timeMatch = _timeRegExp.firstMatch(output);
    return timeMatch?.group(0);
  }

  @override
  bool isSupported() => true;

  @override
  bool get supportsScreenshot => true;

  @override
  Future<bool> takeScreenshot(File outputFile) {
    const String remotePath = '/data/local/tmp/flutter_screenshot.png';

    runCheckedSync(adbCommandForDevice(<String>['shell', 'screencap', '-p', remotePath]));
    runCheckedSync(adbCommandForDevice(<String>['pull', remotePath, outputFile.path]));
    runCheckedSync(adbCommandForDevice(<String>['shell', 'rm', remotePath]));

    return new Future<bool>.value(true);
  }

  @override
  Future<List<DiscoveredApp>> discoverApps() {
    RegExp discoverExp = new RegExp(r'DISCOVER: (.*)');
    List<DiscoveredApp> result = <DiscoveredApp>[];
    StreamSubscription<String> logs = getLogReader().logLines.listen((String line) {
      Match match = discoverExp.firstMatch(line);
      if (match != null) {
        Map<String, dynamic> app = JSON.decode(match.group(1));
        result.add(new DiscoveredApp(app['id'], app['observatoryPort']));
      }
    });

    runCheckedSync(adbCommandForDevice(<String>[
      'shell', 'am', 'broadcast', '-a', 'io.flutter.view.DISCOVER'
    ]));

    return new Future<List<DiscoveredApp>>.delayed(new Duration(seconds: 1), () {
      logs.cancel();
      return result;
    });
  }
}

Map<String, String> parseAdbDeviceProperties(String str) {
  Map<String, String> properties = <String, String>{};
  final RegExp propertyExp = new RegExp(r'\[(.*?)\]: \[(.*?)\]');
  for (Match match in propertyExp.allMatches(str))
    properties[match.group(1)] = match.group(2);
  return properties;
}

// 015d172c98400a03       device usb:340787200X product:nakasi model:Nexus_7 device:grouper
final RegExp _kDeviceRegex = new RegExp(r'^(\S+)\s+(\S+)(.*)');

/// Return the list of connected ADB devices.
///
/// [mockAdbOutput] is public for testing.
List<AndroidDevice> getAdbDevices({ String mockAdbOutput }) {
  List<AndroidDevice> devices = <AndroidDevice>[];
  String text;

  if (mockAdbOutput == null) {
    String adbPath = getAdbPath(androidSdk);
    if (adbPath == null)
      return <AndroidDevice>[];
    text = runSync(<String>[adbPath, 'devices', '-l']);
  } else {
    text = mockAdbOutput;
  }

  // Check for error messages from adb
  if (!text.contains('List of devices')) {
    printError(text);
    return <AndroidDevice>[];
  }

  for (String line in text.trim().split('\n')) {
    // Skip lines like: * daemon started successfully *
    if (line.startsWith('* daemon '))
      continue;

    if (line.startsWith('List of devices'))
      continue;

    if (_kDeviceRegex.hasMatch(line)) {
      Match match = _kDeviceRegex.firstMatch(line);

      String deviceID = match[1];
      String deviceState = match[2];
      String rest = match[3];

      Map<String, String> info = <String, String>{};
      if (rest != null && rest.isNotEmpty) {
        rest = rest.trim();
        for (String data in rest.split(' ')) {
          if (data.contains(':')) {
            List<String> fields = data.split(':');
            info[fields[0]] = fields[1];
          }
        }
      }

      if (info['model'] != null)
        info['model'] = cleanAdbDeviceName(info['model']);

      if (deviceState == 'unauthorized') {
        printError(
          'Device $deviceID is not authorized.\n'
          'You might need to check your device for an authorization dialog.'
        );
      } else if (deviceState == 'offline') {
        printError('Device $deviceID is offline.');
      } else {
        devices.add(new AndroidDevice(
          deviceID,
          productID: info['product'],
          modelID: info['model'] ?? deviceID,
          deviceCodeName: info['device']
        ));
      }
    } else {
      printError(
        'Unexpected failure parsing device information from adb output:\n'
        '$line\n'
        'Please report a bug at https://github.com/flutter/flutter/issues/new');
    }
  }

  return devices;
}

/// A log reader that logs from `adb logcat`.
class _AdbLogReader extends DeviceLogReader {
  _AdbLogReader(this.device) {
    _linesController = new StreamController<String>.broadcast(
      onListen: _start,
      onCancel: _stop
    );
  }

  final AndroidDevice device;

  StreamController<String> _linesController;
  Process _process;

  @override
  Stream<String> get logLines => _linesController.stream;

  @override
  String get name => device.name;

  DateTime _timeOrigin;

  DateTime _adbTimestampToDateTime(String adbTimestamp) {
    // The adb timestamp format is: mm-dd hours:minutes:seconds.milliseconds
    // Dart's DateTime parse function accepts this format so long as we provide
    // the year, resulting in:
    // yyyy-mm-dd hours:minutes:seconds.milliseconds.
    return DateTime.parse('${new DateTime.now().year}-$adbTimestamp');
  }

  void _start() {
    // Start the adb logcat process.
    List<String> args = <String>['logcat', '-v', 'time'];
    String lastTimestamp = device.lastLogcatTimestamp;
    if (lastTimestamp != null)
        _timeOrigin = _adbTimestampToDateTime(lastTimestamp);
    else
        _timeOrigin = null;
    runCommand(device.adbCommandForDevice(args)).then((Process process) {
      _process = process;
      _process.stdout.transform(UTF8.decoder).transform(const LineSplitter()).listen(_onLine);
      _process.stderr.transform(UTF8.decoder).transform(const LineSplitter()).listen(_onLine);

      _process.exitCode.then((int code) {
        if (_linesController.hasListener)
          _linesController.close();
      });
    });
  }

  // 'W/ActivityManager: '
  static final RegExp _logFormat = new RegExp(r'^[VDIWEF]\/.{8,}:\s');

  static final List<RegExp> _whitelistedTags = <RegExp>[
    new RegExp(r'^[VDIWEF]\/flutter[^:]*:\s+', caseSensitive: false),
    new RegExp(r'^[IE]\/DartVM[^:]*:\s+'),
    new RegExp(r'^[WEF]\/AndroidRuntime:\s+'),
    new RegExp(r'^[WEF]\/ActivityManager:\s+.*(\bflutter\b|\bdomokit\b|\bsky\b)'),
    new RegExp(r'^[WEF]\/System\.err:\s+'),
    new RegExp(r'^[F]\/[\S^:]+:\s+')
  ];

  // we default to true in case none of the log lines match
  bool _acceptedLastLine = true;

  // The format of the line is controlled by the '-v' parameter passed to
  // adb logcat. We are currently passing 'time', which has the format:
  // mm-dd hh:mm:ss.milliseconds Priority/Tag( PID): ....
  void _onLine(String line) {
    final Match timeMatch = AndroidDevice._timeRegExp.firstMatch(line);
    if (timeMatch == null) {
      return;
    }
    if (_timeOrigin != null) {
      final String timestamp = timeMatch.group(0);
      DateTime time = _adbTimestampToDateTime(timestamp);
      if (time.isBefore(_timeOrigin)) {
        // Ignore log messages before the origin.
        return;
      }
    }
    if (line.length == timeMatch.end) {
      return;
    }
    // Chop off the time.
    line = line.substring(timeMatch.end + 1);
    if (_logFormat.hasMatch(line)) {
      // Filter on approved names and levels.
      for (RegExp regex in _whitelistedTags) {
        if (regex.hasMatch(line)) {
          _acceptedLastLine = true;
          _linesController.add(line);
          return;
        }
      }
      _acceptedLastLine = false;
    } else if (line == '--------- beginning of system' ||
               line == '--------- beginning of main' ) {
      // hide the ugly adb logcat log boundaries at the start
      _acceptedLastLine = false;
    } else {
      // If it doesn't match the log pattern at all, then pass it through if we
      // passed the last matching line through. It might be a multiline message.
      if (_acceptedLastLine) {
        _linesController.add(line);
        return;
      }
    }
  }

  void _stop() {
    // TODO(devoncarew): We should remove adb port forwarding here.

    _process?.kill();
  }
}

class _AndroidDevicePortForwarder extends DevicePortForwarder {
  _AndroidDevicePortForwarder(this.device);

  final AndroidDevice device;

  static int _extractPort(String portString) {
    return int.parse(portString.trim(), onError: (_) => null);
  }

  @override
  List<ForwardedPort> get forwardedPorts {
    final List<ForwardedPort> ports = <ForwardedPort>[];

    String stdout = runCheckedSync(device.adbCommandForDevice(
      <String>['forward', '--list']
    ));

    List<String> lines = LineSplitter.split(stdout).toList();
    for (String line in lines) {
      if (line.startsWith(device.id)) {
        List<String> splitLine = line.split("tcp:");

        // Sanity check splitLine.
        if (splitLine.length != 3)
          continue;

        // Attempt to extract ports.
        int hostPort = _extractPort(splitLine[1]);
        int devicePort = _extractPort(splitLine[2]);

        // Failed, skip.
        if ((hostPort == null) || (devicePort == null))
          continue;

        ports.add(new ForwardedPort(hostPort, devicePort));
      }
    }

    return ports;
  }

  @override
  Future<int> forward(int devicePort, { int hostPort }) async {
    if ((hostPort == null) || (hostPort == 0)) {
      // Auto select host port.
      hostPort = await findAvailablePort();
    }

    runCheckedSync(device.adbCommandForDevice(
      <String>['forward', 'tcp:$hostPort', 'tcp:$devicePort']
    ));

    return hostPort;
  }

  @override
  Future<Null> unforward(ForwardedPort forwardedPort) async {
    runCheckedSync(device.adbCommandForDevice(
      <String>['forward', '--remove', 'tcp:${forwardedPort.hostPort}']
    ));
  }
}
