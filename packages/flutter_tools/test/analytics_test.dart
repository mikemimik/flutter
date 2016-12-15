// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/create.dart';
import 'package:flutter_tools/src/commands/config.dart';
import 'package:flutter_tools/src/commands/doctor.dart';
import 'package:flutter_tools/src/usage.dart';
import 'package:test/test.dart';

import 'src/common.dart';
import 'src/context.dart';

void main() {
  group('analytics', () {
    Directory temp;

    setUp(() {
      Cache.flutterRoot = '../..';
      temp = Directory.systemTemp.createTempSync('flutter_tools');
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    // Ensure we don't send anything when analytics is disabled.
    testUsingContext('doesn\'t send when disabled', () async {
      int count = 0;
      flutterUsage.onSend.listen((Map<String, dynamic> data) => count++);

      flutterUsage.enabled = false;
      CreateCommand command = new CreateCommand();
      CommandRunner<Null> runner = createTestCommandRunner(command);
      await runner.run(<String>['create', '--no-pub', temp.path]);
      expect(count, 0);

      flutterUsage.enabled = true;
      await runner.run(<String>['create', '--no-pub', temp.path]);
      expect(count, flutterUsage.isFirstRun ? 0 : 2);

      count = 0;
      flutterUsage.enabled = false;
      DoctorCommand doctorCommand = new DoctorCommand();
      runner = createTestCommandRunner(doctorCommand);
      await runner.run(<String>['doctor']);
      expect(count, 0);
    }, overrides: <Type, Generator>{
      Usage: () => new Usage(),
    });

    // Ensure we con't send for the 'flutter config' command.
    testUsingContext('config doesn\'t send', () async {
      int count = 0;
      flutterUsage.onSend.listen((Map<String, dynamic> data) => count++);

      flutterUsage.enabled = false;
      ConfigCommand command = new ConfigCommand();
      CommandRunner<Null> runner = createTestCommandRunner(command);
      await runner.run(<String>['config']);
      expect(count, 0);

      flutterUsage.enabled = true;
      await runner.run(<String>['config']);
      expect(count, 0);
    }, overrides: <Type, Generator>{
      Usage: () => new Usage(),
    });
  });

  group('analytics bots', () {
    testUsingContext('don\'t send on bots', () async {
      int count = 0;
      flutterUsage.onSend.listen((Map<String, dynamic> data) => count++);

      await createTestCommandRunner().run(<String>['--version']);
      expect(count, 0);
    }, overrides: <Type, Generator>{
      Usage: () => new Usage(
        settingsName: 'flutter_bot_test',
        versionOverride: 'dev/unknown',
      ),
    });
  });
}
