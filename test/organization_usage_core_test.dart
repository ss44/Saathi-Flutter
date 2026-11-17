import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saathi/core/saathi_core.dart';

void main() {
  for (final usage in <Map<String, dynamic>>[
    {},
    {'input_tokens': 7},
    {'output_tokens': 0},
    {'input_tokens': -1, 'output_tokens': '3'},
    {'input_tokens': 7, 'output_tokens': 3},
  ]) {
    test('Anthropic reports only supplied valid counters $usage', () async {
      final core = SaathiCore(
          client: MockClient((_) async => http.Response(
              jsonEncode({
                'content': [
                  {'type': 'text', 'text': 'answer'}
                ],
                'usage': usage
              }),
              200)));
      core.addProvider(const ProviderConfig(
          id: 'a', name: 'a', type: ProviderType.anthropic));
      const model = ModelInfo(providerId: 'a', name: 'model');
      core.registerModel(model);
      core.selectModel(model.id);
      final result = await core.sendMessage('hello');
      final expected = <String, dynamic>{
        if (usage['input_tokens'] is int && (usage['input_tokens'] as int) >= 0)
          'promptTokens': usage['input_tokens'],
        if (usage['output_tokens'] is int &&
            (usage['output_tokens'] as int) >= 0)
          'completionTokens': usage['output_tokens'],
      };
      expect(result.metadata, expected);
      core.close();
    });
  }
}
