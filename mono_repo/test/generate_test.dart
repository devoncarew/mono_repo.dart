// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:mono_repo/mono_repo.dart';
import 'package:mono_repo/src/ci_test_script.dart';
import 'package:mono_repo/src/commands/ci_script/generate.dart';
import 'package:mono_repo/src/commands/github/generate.dart'
    show defaultGitHubWorkflowFilePath;
import 'package:mono_repo/src/github_config.dart';
import 'package:mono_repo/src/package_config.dart';
import 'package:mono_repo/src/yaml.dart';
import 'package:path/path.dart' as p;
import 'package:term_glyph/term_glyph.dart' as glyph;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'shared.dart';
import 'src/expected_output.dart';

void main() {
  glyph.ascii = false;

  group('simple bits for configurations', () {
    for (var value in const [true, false, null]) {
      test('value `$value`', () async {
        final monoConfigContent = toYaml({'github': value});
        await populateConfig(monoConfigContent);

        final expected = [
          'package:sub_pkg',
          'Wrote `${p.join(d.sandbox, defaultGitHubWorkflowFilePath)}`.',
          ciScriptPathMessage,
        ].join('\n');

        testGenerateConfig(
          printMatcher: expected,
        );
      });
    }
  });

  test('no package', () async {
    await d.dir('sub_pkg').create();

    expect(
      testGenerateConfig,
      throwsUserExceptionWith(
        'No packages found.',
        details: 'Each target package directory must contain a '
            '`mono_pkg.yaml` file.',
      ),
    );
  });

  test('$monoPkgFileName with non-Map contents', () async {
    await d.dir('sub_pkg', [
      d.file('mono_pkg.yaml', 'bob'),
      d.file('pubspec.yaml', '''
name: pkg_name
      ''')
    ]).create();

    final path = p.join('sub_pkg', 'mono_pkg.yaml');
    expect(
      testGenerateConfig,
      throwsUserExceptionWith('The contents of `$path` must be a Map.'),
    );
  });

  test('empty $monoPkgFileName file', () async {
    await d.dir('sub_pkg', [
      d.file('mono_pkg.yaml', '# just a comment!'),
      d.file('pubspec.yaml', '''
name: pkg_name
      ''')
    ]).create();

    expect(
      () => testGenerateConfig(
        printMatcher: '''
package:sub_pkg''',
      ),
      throwsUserExceptionWith(
        'No entries created. Check your nested `$monoPkgFileName` files.',
      ),
    );
  });

  test('fails with unsupported configuration', () async {
    await d.dir('sub_pkg', [
      d.file(monoPkgFileName, r'''
sdk:
  - dev

stages:
  - unit_test:
    # Doing the hole xvfb thing is broken - for now!
    - test: --platform chrome
      xvfb: true
'''),
      d.file('pubspec.yaml', '''
name: pkg_name
      ''')
    ]).create();

    expect(
      testGenerateConfig,
      throwsAParsedYamlException(
        startsWith(
          'line 8, column 7 of ${p.join('sub_pkg', 'mono_pkg.yaml')}: '
          'Extra config options are not currently supported.',
        ),
      ),
    );
  });

  test('fails with unsupported Dart version', () async {
    await d.dir('sub_pkg', [
      d.file(monoPkgFileName, r'''
sdk:
  - not_a_dart

stages:
  - unit_test:
    - test
'''),
      d.file('pubspec.yaml', '''
name: pkg_name
      ''')
    ]).create();

    expect(
      testGenerateConfig,
      throwsAParsedYamlException(
        startsWith(
          'line 2, column 3 of ${p.join('sub_pkg', 'mono_pkg.yaml')}: '
          'Unsupported value for "sdk". The value "not_a_dart" is neither a '
          'version string nor one of "main", "pubspec", "dev", "beta", '
          '"stable".',
        ),
      ),
    );
  });

  group('fails with duplicate dart versions', () {
    for (var values in [
      ['stable', 'stable'],
      ['main', 'edge'],
      ['main', 'be/raw/latest'],
    ]) {
      group('$values', () {
        test('root of mono_pkg', () async {
          await d.dir('sub_pkg', [
            d.file(
              monoPkgFileName,
              jsonEncode({
                'sdk': values,
                'stages': [
                  {
                    'unit_test': ['test']
                  }
                ]
              }),
            ),
            d.file('pubspec.yaml', '''
name: pkg_name
      ''')
          ]).create();

          expect(
            testGenerateConfig,
            throwsAParsedYamlException(
              startsWith(
                'line 1, column 8 of ${p.join('sub_pkg', 'mono_pkg.yaml')}: '
                'Unsupported value for "sdk". "${values.first}" appears more '
                'than once.',
              ),
            ),
          );
        });

        test('within test', () async {
          await d.dir('sub_pkg', [
            d.file(
              monoPkgFileName,
              jsonEncode({
                'stages': [
                  {
                    'unit_test': [
                      {
                        'test': '',
                        'sdk': values,
                      }
                    ]
                  }
                ]
              }),
            ),
            d.file('pubspec.yaml', '''
name: pkg_name
      ''')
          ]).create();

          expect(
            testGenerateConfig,
            throwsAParsedYamlException(
              startsWith(
                'line 1, column 43 of ${p.join('sub_pkg', 'mono_pkg.yaml')}: '
                'Unsupported value for "sdk". "${values.first}" appears more '
                'than once.',
              ),
            ),
          );
        });
      });
    }
  });

  test('fails with legacy file name', () async {
    await d.dir('sub_pkg', [
      d.file('.mono_repo.yml', ''),
      d.file('pubspec.yaml', '''
name: pkg_name
      ''')
    ]).create();

    expect(
      testGenerateConfig,
      throwsUserExceptionWith(
        'Found legacy package configuration file '
        '(".mono_repo.yml") in `sub_pkg`.',
        details: 'Rename to "mono_pkg.yaml".',
      ),
    );
  });

  test('conflicting stage orders are not allowed', () async {
    await d.dir('pkg_a', [
      d.file(monoPkgFileName, r'''
sdk:
 - dev

stages:
  - format:
    - format
  - analyze:
    - analyze
'''),
      d.file('pubspec.yaml', '''
name: pkg_a
      ''')
    ]).create();

    await d.dir('pkg_b', [
      d.file(monoPkgFileName, r'''
sdk:
 - dev

stages:
  - analyze:
    - analyze
  - format:
    - format: sdk
'''),
      d.file('pubspec.yaml', '''
name: pkg_b
      ''')
    ]).create();

    expect(
      () => testGenerateConfig(
        printMatcher: '''
package:pkg_a
package:pkg_b''',
      ),
      throwsUserExceptionWith(
        'Not all packages agree on `stages` ordering, found a cycle '
        'between the following stages: `analyze`, `format`.',
      ),
    );
  });

  group('--validate', () {
    setUp(() async {
      await d.dir('sub_pkg', [
        d.file(monoPkgFileName, testConfig2),
        d.file('pubspec.yaml', '''
name: pkg_name
      ''')
      ]).create();
    });

    test('throws if there is no generated config', () async {
      expect(
        () => testGenerateConfig(
          validateOnly: true,
          printMatcher: 'package:sub_pkg',
        ),
        throwsA(isA<UserException>()),
      );
    });

    test("throws if the previous config doesn't match", () async {
      await d.file(defaultGitHubWorkflowFileName, '').create();
      expect(
        () => testGenerateConfig(
          validateOnly: true,
          printMatcher: 'package:sub_pkg',
        ),
        throwsA(isA<UserException>()),
      );
    });

    test("doesn't throw if the previous config is up to date", () async {
      testGenerateConfig(
        printMatcher: _subPkgStandardOutput,
      );

      // Just check that this doesn't throw.
      testGenerateConfig(
        printMatcher: '''
package:sub_pkg
Wrote `${p.join(d.sandbox, defaultGitHubWorkflowFilePath)}`.
Wrote `${p.join(d.sandbox, ciScriptPath)}`.''',
      );
    });
  });

  test('complete travis.yml file', () async {
    await d.dir('sub_pkg', [
      d.file(monoPkgFileName, testConfig2),
      d.file('pubspec.yaml', '''
name: pkg_name
      ''')
    ]).create();

    testGenerateConfig(
      printMatcher: _subPkgStandardOutput,
    );
    await d.file(ciScriptPath, ciShellOutput).validate();
  });

  test('incompatible SDK constraints', () async {
    await d.dir('sub_pkg', [
      d.file(monoPkgFileName, testConfig2),
      d.file('pubspec.yaml', '''
name: pkg_name
environment:
  sdk: '>=2.1.0 <3.0.0'
''')
    ]).create();

    testGenerateConfig(
      printMatcher: '''
package:sub_pkg
  There are jobs defined that are not compatible with the package SDK constraint (>=2.1.0 <3.0.0): `1.23.0`.
$_writeScriptOutput''',
    );

    await d.file(ciScriptPath, ciShellOutput).validate();
  });

  test('max cache key', () async {
    final monoConfigContent = toYaml({
      'merge_stages': ['format']
    });
    await populateConfig(monoConfigContent);

    String pkgName(int i) => 'package_with_a_long_name_'
        '${i.toString().padLeft(2, '0')}';

    const count = 18;

    for (var i = 0; i < count; i++) {
      await d.dir(pkgName(i), [
        d.file(monoPkgFileName, r'''
sdk:
 - dev

stages:
  - format:
    - format
'''),
        d.file('pubspec.yaml', '''
name: pkg_a
      ''')
      ]).create();
    }

    testGenerateConfig(
      printMatcher: '''
${Iterable.generate(count, (i) => 'package:${pkgName(i)}').join('\n')}
package:sub_pkg
$_writeScriptOutput''',
    );

    validateSandbox(
      'max_cache_key.txt',
      defaultGitHubWorkflowFilePath,
    );
  });

  test('two flavors of dartfmt', () async {
    await d.dir('pkg_a', [
      d.file(monoPkgFileName, r'''
sdk:
 - stable
 - dev

stages:
  - format:
    - format

cache:
  directories:
    - .dart_tool
    - /some_repo_root_dir
'''),
      d.file('pubspec.yaml', '''
name: pkg_a
      ''')
    ]).create();

    await d.dir('pkg_b', [
      d.file(monoPkgFileName, r'''
sdk:
 - dev

stages:
  - format:
    - format: sdk

cache:
  directories:
    - .dart_tool
    - /some_repo_root_dir
'''),
      d.file('pubspec.yaml', '''
name: pkg_b
      ''')
    ]).create();

    testGenerateConfig(
      printMatcher: '''
package:pkg_a
package:pkg_b
$_writeScriptOutput''',
    );

    validateSandbox(
      'two_dartfmt_flavors.txt',
      defaultGitHubWorkflowFilePath,
    );

    await d
        .file(
          ciScriptPath,
          contains(r'''
      case ${TASK} in
      format)
        echo 'dart format --output=none --set-exit-if-changed .'
        dart format --output=none --set-exit-if-changed . || EXIT_CODE=$?
        ;;
      *)
        echo -e "\033[31mUnknown TASK '${TASK}' - TERMINATING JOB\033[0m"
        exit 64
        ;;
      esac
'''),
        )
        .validate();
  });

  test('two flavors of dartfmt with different arguments', () async {
    await d.dir('pkg_a', [
      d.file(monoPkgFileName, r'''
sdk:
 - stable
 - dev

stages:
  - format:
    - format: sdk

cache:
  directories:
    - .dart_tool
    - /some_repo_root_dir
'''),
      d.file('pubspec.yaml', '''
name: pkg_a
      ''')
    ]).create();

    await d.dir('pkg_b', [
      d.file(monoPkgFileName, r'''
sdk:
 - dev

stages:
  - format:
    - format: --dry-run --fix --set-exit-if-changed .

cache:
  directories:
    - .dart_tool
    - /some_repo_root_dir
'''),
      d.file('pubspec.yaml', '''
name: pkg_b
      ''')
    ]).create();

    testGenerateConfig(
      printMatcher: '''
package:pkg_a
package:pkg_b
$_writeScriptOutput''',
    );

    validateSandbox(
      'two_dartfmt_flavors_different_args.txt',
      defaultGitHubWorkflowFilePath,
    );

    await d
        .file(
          ciScriptPath,
          contains(r'''
      case ${TASK} in
      format_0)
        echo 'dart format --output=none --set-exit-if-changed .'
        dart format --output=none --set-exit-if-changed . || EXIT_CODE=$?
        ;;
      format_1)
        echo 'dart format --dry-run --fix --set-exit-if-changed .'
        dart format --dry-run --fix --set-exit-if-changed . || EXIT_CODE=$?
        ;;
      *)
        echo -e "\033[31mUnknown TASK '${TASK}' - TERMINATING JOB\033[0m"
        exit 64
        ;;
      esac
'''),
        )
        .validate();
  });

  test('missing `dart` key', () async {
    await d.dir('pkg_a', [
      d.file(monoPkgFileName, r'''
stages:
  - format:
    - dartfmt:
'''),
      d.file('pubspec.yaml', '''
name: pkg_a
      ''')
    ]).create();

    expect(
      testGenerateConfig,
      throwsAParsedYamlException('''
line 3, column 7 of ${p.normalize('pkg_a/mono_pkg.yaml')}: An "sdk" key is required.
  ╷
3 │     - dartfmt:
  │       ^^^^^^^^
  ╵'''),
    );
  });

  test('top-level `dart` and `os` key values are a no-op with group overrides',
      () async {
    await d.dir('pkg_a', [
      d.file(monoPkgFileName, r'''
sdk:
- stable
os:
- unneeded

stages:
  - analyze:
    - group:
        - analyze
        - format
      sdk:
        - dev
      os:
        - osx
    - analyze:
      sdk:
        - 1.23.0
      os:
        - windows
  - unit_test:
    - description: "chrome tests"
      test: --platform chrome
      sdk: dev
      os: macos
    - test: --preset travis
      sdk: stable
      os: linux
'''),
      d.file('pubspec.yaml', '''
name: pkg_a
      ''')
    ]).create();

    testGenerateConfig(
      printMatcher: '''
package:pkg_a
  `dart` values (stable) are not used and can be removed.
  `os` values (unneeded) are not used and can be removed.
$_writeScriptOutput''',
    );

    validateSandbox(
      'github_output_group_overrides.txt',
      defaultGitHubWorkflowFilePath,
    );

    await d.file(ciScriptPath, ciShellOutput).validate();
  });

  test('test_with_coverage', () async {
    await d.dir('pkg_a', [
      d.file(monoPkgFileName, r'''
stages:
  - test:
    - description: "chrome tests"
      test: --platform chrome
      sdk: dev
      os: macos
    - test_with_coverage: --preset travis
      sdk: stable
'''),
      d.file('pubspec.yaml', '''
name: pkg_a
      ''')
    ]).create();

    testGenerateConfig(
      printMatcher: '''
package:pkg_a
$_writeScriptOutput''',
    );

    validateSandbox(
      'github_output_test_with_coverage.txt',
      defaultGitHubWorkflowFilePath,
    );
  });

  test('test_with_coverage not supported with flutter', () async {
    await d.dir('pkg_a', [
      d.file(monoPkgFileName, r'''
stages:
  - test:
    - test_with_coverage:
      sdk: stable
'''),
      d.file('pubspec.yaml', '''
name: pkg_a

environment:
  sdk: ">=2.17.0 <3.0.0"

dependencies:
  flutter:
    sdk: flutter
      ''')
    ]).create();

    expect(
      testGenerateConfig,
      throwsAParsedYamlException('''
line 3, column 25 of ${p.join('pkg_a', 'mono_pkg.yaml')}: Unsupported value for "test_with_coverage". Code coverage tests are not supported with Flutter.
  ╷
3 │     - test_with_coverage:
  │                         ^
  ╵'''),
    );
  });

  test(
    'command values must be either a String or a List containing strings',
    () async {
      await d.dir('pkg_a', [
        d.file(monoPkgFileName, r'''
sdk:
- dev

stages:
- unit_test:
  - command: {a:b}
'''),
        d.file('pubspec.yaml', '''
name: pkg_a
''')
      ]).create();

      expect(
        testGenerateConfig,
        throwsAParsedYamlException('''
line 6, column 14 of ${p.join('pkg_a', 'mono_pkg.yaml')}: Unsupported value for "command". Only supports a string or array of strings
  ╷
6 │   - command: {a:b}
  │              ^^^^^
  ╵'''),
      );
    },
  );

  test('bad yaml', () async {
    await d.dir('pkg_a', [
      d.file(monoPkgFileName, r'''
sdk:
- dev

stages:
- unit_test
  - before_script: "echo hi"
''')
    ]).create();

    expect(
      testGenerateConfig,
      throwsAParsedYamlException('''
line 6, column 18 of ${p.join('pkg_a', 'mono_pkg.yaml')}: Mapping values are not allowed here. Did you miss a colon earlier?
  ╷
6 │   - before_script: "echo hi"
  │                  ^
  ╵'''),
    );
  });

  test('double digit commands', () async {
    final lines = Iterable.generate(
      11,
      (i) => '    - test: --preset travis --total-shards 9 --shard-index $i',
    ).join('\n');

    await d.dir('pkg_a', [
      d.file('pubspec.yaml', '''
name: pkg_a
'''),
      d.file(monoPkgFileName, '''
sdk:
- dev

stages:
  - unit_test:
$lines
''')
    ]).create();

    testGenerateConfig(printMatcher: isNotEmpty);

    await d
        .file(
          ciScriptPath,
          stringContainsInOrder([
            'test_00)',
            'test_10)',
          ]),
        )
        .validate();
  });

  group('mono_repo.yaml', () {
    Future<void> validConfig(
      String monoRepoContent, {
      Object? expectedGithubContent,
    }) async {
      await populateConfig(monoRepoContent);

      if (expectedGithubContent != null) {
        await d.nothing(defaultGitHubWorkflowFilePath).validate();
      }
      await d.nothing(ciScriptPath).validate();

      testGenerateConfig(
        printMatcher: _subPkgStandardOutput,
      );

      if (expectedGithubContent != null) {
        await d
            .file(defaultGitHubWorkflowFilePath, expectedGithubContent)
            .validate();
      }
      await d.file(ciScriptPath, ciShellOutput).validate();
    }

    test(
      'disallows unsupported keys',
      () => _testBadConfig(
        {
          'other': {'stages': 5}
        },
        r'''
line 2, column 3 of mono_repo.yaml: Unsupported value for "other". Only `github`, `merge_stages`, `pretty_ansi`, `pub_action`, `self_validate`, `coverage_service` keys are supported.
  ╷
2 │   stages: 5
  │   ^^^^^^^^^
  ╵''',
      ),
    );

    group('merge_stages', () {
      test(
        'must be a list',
        () => _testBadConfig(
          {
            'merge_stages': {'stages': 5}
          },
          startsWith(
            'line 2, column 3 of mono_repo.yaml: Unsupported value for '
            '"merge_stages". `merge_stages` must be an array.',
          ),
        ),
      );

      test(
        'must be String items',
        () => _testBadConfig(
          {
            'merge_stages': [5]
          },
          startsWith(
            'line 2, column 3 of mono_repo.yaml: Unsupported value for '
            '"merge_stages". All values must be strings.',
          ),
        ),
      );

      test('must match a configured stage from pkg_config', () async {
        final monoConfigContent = toYaml({
          'merge_stages': ['bob']
        });
        await populateConfig(monoConfigContent);
        expect(
          () => testGenerateConfig(printMatcher: 'package:sub_pkg'),
          throwsUserExceptionWith(
            'Error parsing mono_repo.yaml',
            details:
                'One or more stage was referenced in `mono_repo.yaml` that do '
                'not exist in any `mono_pkg.yaml` files: `bob`.',
          ),
        );
      });

      test('should merge correctly', () async {
        await d.file('mono_repo.yaml', '''
merge_stages: [analyze]
''').create();

        await d.dir('pkg_a', [
          d.file(monoPkgFileName, r'''
sdk:
 - stable

stages:
  - analyze:
    - group:
        - analyze
        - format
  - unit_test:
    - description: "chrome tests"
      test: --platform chrome
    - test: --preset travis
'''),
          d.file('pubspec.yaml', r'''
name: pkg_a
''')
        ]).create();

        await d.dir('pkg_b', [
          d.file(monoPkgFileName, r'''
sdk:
 - stable

stages:
  - analyze:
    - group:
        - analyze
        - format
  - unit_test:
    - description: "chrome tests"
      test: --platform chrome
    - test: --preset travis
'''),
          d.file('pubspec.yaml', '''
name: pkg_b
      ''')
        ]).create();

        await d.dir('pkg_c', [
          d.file(monoPkgFileName, r'''
sdk:
 - stable

stages:
  - analyze:
    - group:
        - analyze
        - format
'''),
          d.file('pubspec.yaml', '''
name: pkg_c
dependencies:
  flutter:
    sdk: flutter
      ''')
        ]).create();

        testGenerateConfig(
          printMatcher: '''
package:pkg_a
package:pkg_b
package:pkg_c
$_writeScriptOutput''',
        );

        validateSandbox(
          'should_merge_correctly.txt',
          defaultGitHubWorkflowFilePath,
        );

        await d.file(ciScriptPath, ciShellOutputMultiFlavor).validate();
      });
    });

    group('pub_action', () {
      test(
        'value must be a String',
        () => _testBadConfig({
          'pub_action': 42,
        }, r'''
line 1, column 13 of mono_repo.yaml: Unsupported value for "pub_action". Value must be one of: `get`, `upgrade`.
  ╷
1 │ pub_action: 42
  │             ^^
  ╵'''),
      );

      test(
        'value must be in allowed list',
        () => _testBadConfig({'pub_action': 'bob'}, r'''
line 1, column 13 of mono_repo.yaml: Unsupported value for "pub_action". Value must be one of: `get`, `upgrade`.
  ╷
1 │ pub_action: bob
  │             ^^^
  ╵'''),
      );

      test('upgrade', () async {
        final monoConfigContent = toYaml({'pub_action': 'upgrade'});

        await populateConfig(monoConfigContent);

        testGenerateConfig(
          printMatcher: _subPkgStandardOutput,
        );

        // TODO: validate GitHub case
        await d.file(ciScriptPath, ciShellOutput).validate();
      });

      test('get', () async {
        final monoConfigContent = toYaml({'pub_action': 'get'});

        await populateConfig(monoConfigContent);

        testGenerateConfig(
          printMatcher: _subPkgStandardOutput,
        );

        // TODO: validate GitHub case
        await d
            .file(
              ciScriptPath,
              contains(r'''
  dart pub get || EXIT_CODE=$?

  if [[ ${EXIT_CODE} -ne 0 ]]; then
    echo -e "\033[31mPKG: ${PKG}; 'dart pub get' - FAILED  (${EXIT_CODE})\033[0m"
    FAILURES+=("${PKG}; 'dart pub get'")
  else
'''),
            )
            .validate();
      });
    });

    group('pretty_ansi', () {
      test(
        'value must be bool',
        () => _testBadConfig({'pretty_ansi': 'not a bool!'}, r'''
line 1, column 14 of mono_repo.yaml: Unsupported value for "pretty_ansi". Value must be `true` or `false`.
  ╷
1 │ pretty_ansi: "not a bool!"
  │              ^^^^^^^^^^^^^
  ╵'''),
      );

      test('set to false', () async {
        await populateConfig(toYaml({'pretty_ansi': false}));

        testGenerateConfig(
          printMatcher: _subPkgStandardOutput,
        );

        await d
            .file(
                ciScriptPath,
                '''
$bashScriptHeader

'''
                r'''
if [[ -z ${PKGS} ]]; then
  echo -e 'PKGS environment variable must be set! - TERMINATING JOB'
  exit 64
fi

if [[ "$#" == "0" ]]; then
  echo -e 'At least one task argument must be provided! - TERMINATING JOB'
  exit 64
fi

SUCCESS_COUNT=0
declare -a FAILURES

for PKG in ${PKGS}; do
  echo -e "PKG: ${PKG}"
  EXIT_CODE=0
  pushd "${PKG}" >/dev/null || EXIT_CODE=$?

  if [[ ${EXIT_CODE} -ne 0 ]]; then
    echo -e "PKG: '${PKG}' does not exist - TERMINATING JOB"
    exit 64
  fi

  dart pub upgrade || EXIT_CODE=$?

  if [[ ${EXIT_CODE} -ne 0 ]]; then
    echo -e "PKG: ${PKG}; 'dart pub upgrade' - FAILED  (${EXIT_CODE})"
    FAILURES+=("${PKG}; 'dart pub upgrade'")
  else
    for TASK in "$@"; do
      EXIT_CODE=0
      echo
      echo -e "PKG: ${PKG}; TASK: ${TASK}"
      case ${TASK} in
      analyze)
        echo 'dart analyze'
        dart analyze || EXIT_CODE=$?
        ;;
      format)
        echo 'dart format --output=none --set-exit-if-changed .'
        dart format --output=none --set-exit-if-changed . || EXIT_CODE=$?
        ;;
      test_0)
        echo 'dart test --platform chrome'
        dart test --platform chrome || EXIT_CODE=$?
        ;;
      test_1)
        echo 'dart test --preset travis'
        dart test --preset travis || EXIT_CODE=$?
        ;;
      *)
        echo -e "Unknown TASK '${TASK}' - TERMINATING JOB"
        exit 64
        ;;
      esac

      if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo -e "PKG: ${PKG}; TASK: ${TASK} - FAILED (${EXIT_CODE})"
        FAILURES+=("${PKG}; TASK: ${TASK}")
      else
        echo -e "PKG: ${PKG}; TASK: ${TASK} - SUCCEEDED"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      fi

    done
  fi

  echo
  echo -e "SUCCESS COUNT: ${SUCCESS_COUNT}"

  if [ ${#FAILURES[@]} -ne 0 ]; then
    echo -e "FAILURES: ${#FAILURES[@]}"
    for i in "${FAILURES[@]}"; do
      echo -e "  $i"
    done
  fi

  popd >/dev/null || exit 70
  echo
done

if [ ${#FAILURES[@]} -ne 0 ]; then
  exit 1
fi
''')
            .validate();
      });
    });

    group('self_validate', () {
      test(
        'value must be bool or string',
        () => _testBadConfig({'self_validate': 42}, r'''
line 1, column 16 of mono_repo.yaml: Unsupported value for "self_validate". Value must be `true`, `false`, or a stage name.
  ╷
1 │ self_validate: 42
  │                ^^
  ╵'''),
      );

      test('set to `true`', () async {
        final monoConfigContent = toYaml({'self_validate': true});

        await populateConfig(monoConfigContent);

        testGenerateConfig(
          printMatcher: _subPkgStandardOutput,
        );

        validateSandbox(
          'self_validate_set_to_true.txt',
          defaultGitHubWorkflowFilePath,
        );

        await d.file(ciScriptPath, ciShellOutput).validate();
      });

      test('set to a stage name', () async {
        final monoConfigContent = toYaml({'self_validate': 'analyze'});

        await populateConfig(monoConfigContent);

        testGenerateConfig(
          printMatcher: _subPkgStandardOutput,
        );

        validateSandbox(
          'self_validate_set_to_a_stage_name.txt',
          defaultGitHubWorkflowFilePath,
        );

        await d.file(ciScriptPath, ciShellOutput).validate();
      });
    });

    test('global env', () async {
      await validConfig(
        r'''
github:
  env:
    FOO: BAR
''',
        expectedGithubContent: contains('''
env:
  PUB_ENVIRONMENT: bot.github
  FOO: BAR
'''),
      );
    });
  });

  group('pubspec version', () {
    test('valid', () async {
      await d.dir('pkg_a', [
        d.file(
          monoPkgFileName,
          r'''
sdk:
- pubspec
- dev

stages:
- analyze_and_format:
  - analyze: --fatal-infos .
    sdk:
    - dev
  - analyze:
    sdk:
    - pubspec
  - format:
    sdk:
    - dev
- unit_test:
  - test: --test-randomize-ordering-seed=random
  - test: --test-randomize-ordering-seed=random -p chrome
    os:
    - linux
    - windows
''',
        ),
        d.file('pubspec.yaml', '''
name: pkg_a
environment:
  sdk: '>=2.16.0 <3.0.0'
''')
      ]).create();

      testGenerateConfig(
        printMatcher: '''
package:pkg_a
$_writeScriptOutput''',
      );

      validateSandbox(
        'valid_pubspec_version.txt',
        defaultGitHubWorkflowFilePath,
      );
    });

    test('no SDK constraint - with top-level `pubspec` usage', () async {
      await d.dir('pkg_a', [
        d.file(
          monoPkgFileName,
          r'''
sdk:
- pubspec
- dev

stages:
- analyze_and_format:
  - analyze: --fatal-infos .
''',
        ),
        d.file('pubspec.yaml', '''
name: pkg_a
''')
      ]).create();

      expect(
        testGenerateConfig,
        throwsAParsedYamlException('''
line 2, column 1 of ${p.join('pkg_a', 'mono_pkg.yaml')}: Unsupported value for "sdk". `pubspec` is only valid for packages that have an environment->sdk value defined in `pubspec.yaml`.
  ╷
2 │ ┌ - pubspec
3 │ │ - dev
4 │ └ 
  ╵'''),
      );
    });

    test('no SDK constraint - with job `pubspec` usage', () async {
      await d.dir('pkg_a', [
        d.file(
          monoPkgFileName,
          r'''
stages:
- analyze_and_format:
  - analyze: --fatal-infos .
    sdk: pubspec
''',
        ),
        d.file('pubspec.yaml', '''
name: pkg_a
''')
      ]).create();

      expect(
        testGenerateConfig,
        throwsAParsedYamlException('''
line 4, column 10 of ${p.join('pkg_a', 'mono_pkg.yaml')}: Unsupported value for "sdk". `pubspec` is only valid for packages that have an environment->sdk value defined in `pubspec.yaml`.
  ╷
4 │     sdk: pubspec
  │          ^^^^^^^
  ╵'''),
      );
    });

    test('not supported with flutter', () async {
      await d.dir('pkg_a', [
        d.file(
          monoPkgFileName,
          r'''
stages:
- analyze_and_format:
  - analyze: --fatal-infos .
    sdk: pubspec
''',
        ),
        d.file('pubspec.yaml', '''
name: pkg_a

environment:
  sdk: ">=2.17.0 <3.0.0"

dependencies:
  flutter:
    sdk: flutter
''')
      ]).create();

      expect(
        testGenerateConfig,
        throwsAParsedYamlException('''
line 4, column 10 of ${p.join('pkg_a', 'mono_pkg.yaml')}: Unsupported value for "sdk". `pubspec` is only valid for Dart packages (not Flutter).
  ╷
4 │     sdk: pubspec
  │          ^^^^^^^
  ╵'''),
      );
    });
  });
}

String get _subPkgStandardOutput => '''
package:sub_pkg
$_writeScriptOutput''';

String get _writeScriptOutput => '''
Wrote `${p.join(d.sandbox, defaultGitHubWorkflowFilePath)}`.
$ciScriptPathMessage''';

Future<void> _testBadConfig(
  Object monoRepoYaml,
  Object expectedParsedYaml,
) async {
  final monoConfigContent = toYaml(monoRepoYaml);
  await populateConfig(monoConfigContent);
  expect(
    testGenerateConfig,
    throwsAParsedYamlException(expectedParsedYaml),
  );
}
