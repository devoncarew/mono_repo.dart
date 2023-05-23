// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('action versions are up to date', () {
    expect(
      Process.runSync(
        Platform.executable,
        ['tool/generate_action_versions.dart', '--validate'],
      ).exitCode,
      0,
    );
  });
}
