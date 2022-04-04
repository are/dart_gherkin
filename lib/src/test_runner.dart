import 'dart:async';
import 'package:gherkin/gherkin.dart';
import 'package:gherkin/src/gherkin/languages/language_service.dart';

import './configuration.dart';
import './feature_file_runner.dart';
import './gherkin/expressions/gherkin_expression.dart';
import './gherkin/expressions/tag_expression.dart';
import './gherkin/parameters/custom_parameter.dart';
import './gherkin/parameters/plural_parameter.dart';
import './gherkin/parameters/word_parameter.dart';
import './gherkin/parameters/string_parameter.dart';
import './gherkin/parameters/int_parameter.dart';
import './gherkin/parameters/float_parameter.dart';
import './gherkin/parser.dart';
import './gherkin/runnables/feature_file.dart';
import './gherkin/steps/executable_step.dart';
import './gherkin/steps/step_definition.dart';
import './hooks/aggregated_hook.dart';
import './hooks/hook.dart';
import './reporters/aggregated_reporter.dart';
import './reporters/message_level.dart';
import './reporters/reporter.dart';
import 'gherkin/exceptions/test_run_failed_exception.dart';

class GherkinRunner {
  final _reporter = AggregatedReporter();
  final _hook = AggregatedHook();
  final _parser = GherkinParser();
  final _languageService = LanguageService();
  final _tagExpressionEvaluator = TagExpressionEvaluator();
  final List<ExecutableStep> _executableSteps = <ExecutableStep>[];
  final List<CustomParameter> _customParameters = <CustomParameter>[];

  Future<void> execute(TestConfiguration config) async {
    config.prepare();
    _registerReporters(config.reporters);
    _registerHooks(config.hooks);
    _registerCustomParameters(config.customStepParameterDefinitions);
    _registerStepDefinitions(config.stepDefinitions);
    _languageService.initialise(config.featureDefaultLanguage);

    var featureFiles = await _getFeatureFiles(config);

    var allFeaturesPassed = true;

    if (config.order == ExecutionOrder.random) {
      await _reporter.message(
        'Executing features in random order',
        MessageLevel.info,
      );
      featureFiles = featureFiles.toList()..shuffle();
    } else if (config.order == ExecutionOrder.alphabetical) {
      await _reporter.message(
        'Executing features in sorted order',
        MessageLevel.info,
      );
      featureFiles.sort(
        (FeatureFile a, FeatureFile b) => a.name.compareTo(b.name),
      );
    }

    await _hook.onBeforeRun(config);

    try {
      await _reporter.onTestRunStarted();
      for (var featureFile in featureFiles) {
        final runner = FeatureFileRunner(
          config,
          _tagExpressionEvaluator,
          _executableSteps,
          _reporter,
          _hook,
        );
        allFeaturesPassed &= await runner.run(featureFile);
        if (config.stopAfterTestFailed && !allFeaturesPassed) {
          break;
        }
      }
    } finally {
      await _reporter.onTestRunFinished();
      await _hook.onAfterRun(config);
      await _reporter.dispose();

      if (!allFeaturesPassed) {
        throw GherkinTestRunFailedException();
      }
    }
  }

  Future<List<FeatureFile>> _getFeatureFiles(TestConfiguration config) async {
    try {
      final featureFiles = <FeatureFile>[];

      for (var pattern in config.features) {
        final paths = await config.featureFileMatcher.listFiles(pattern);

        for (var path in paths) {
          await _reporter.message(
            "Found feature file '$path'",
            MessageLevel.verbose,
          );

          final contents = await config.featureFileReader.read(path);

          try {
            final featureFile = await _parser.parseFeatureFile(
              contents,
              path,
              _reporter,
              _languageService,
            );

            featureFiles.add(featureFile);
          } catch (e) {
            if (e.toString() == "Exception: Unknown runnable child given to Scenario 'TextLineRunnable'" ||
                e.toString() == "Exception: Unknown runnable child given to Scenario 'ExampleRunnable'") {
              await _reporter.message(
                'Unable to parse a feature file at "$path": $e',
                MessageLevel.error,
              );
            } else {
              rethrow;
            }
          }
        }
      }

      if (featureFiles.isEmpty) {
        await _reporter.message(
          'No feature files found to run, exiting without running any scenarios',
          MessageLevel.warning,
        );
      } else {
        await _reporter.message(
          'Found ${featureFiles.length} feature file(s) to run',
          MessageLevel.info,
        );
      }

      return featureFiles;
    } catch (e) {
      print(e);
      throw Exception(
        'Error when trying to find feature files with patterns'
        '${config.features.map((e) => e.toString()).join(', ')}`'
        'ERROR: `${e.toString()}`',
      );
    }
  }

  void _registerStepDefinitions(
    Iterable<StepDefinitionGeneric>? stepDefinitions,
  ) {
    if (stepDefinitions != null) {
      stepDefinitions.forEach(
        (s) {
          _executableSteps.add(
            ExecutableStep(
                GherkinExpression(
                  s.pattern is RegExp ? s.pattern as RegExp : RegExp(s.pattern.toString()),
                  _customParameters,
                ),
                s),
          );
        },
      );
    }
  }

  void _registerCustomParameters(Iterable<CustomParameter>? customParameters) {
    _customParameters.add(FloatParameterLower());
    _customParameters.add(FloatParameterCamel());
    _customParameters.add(NumParameterLower());
    _customParameters.add(NumParameterCamel());
    _customParameters.add(IntParameterLower());
    _customParameters.add(IntParameterCamel());
    _customParameters.add(StringParameterLower());
    _customParameters.add(StringParameterCamel());
    _customParameters.add(WordParameterLower());
    _customParameters.add(WordParameterCamel());
    _customParameters.add(PluralParameter());

    if (customParameters != null) {
      _customParameters.addAll(customParameters);
    }
  }

  void _registerReporters(Iterable<Reporter>? reporters) {
    if (reporters != null) {
      reporters.forEach((r) => _reporter.addReporter(r));
    }
  }

  void _registerHooks(Iterable<Hook>? hooks) {
    if (hooks != null) {
      _hook.addHooks(hooks);
    }
  }
}
