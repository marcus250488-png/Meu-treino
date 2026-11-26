import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:treino_app/state.dart';

void main() {
  test('compressão ida e volta mantém os dados e reduz o tamanho', () {
    final m = <String, dynamic>{
      'sessoes': List.generate(500, (i) => 'treino de peito numero $i'),
      'meta_agua': 2500,
    };
    final z = comprimirJson(m);
    expect(descomprimirJson(z), equals(m));
    expect(z.length, lessThan(jsonEncode(m).length));
  });

  test('impressão ignora hora, passos e xp, mas detecta mudança real', () {
    final a = <String, dynamic>{
      'agua': '{}', 'passos': '1', 'xp': '1', 'atualizado_em': 'x'};
    final b = Map<String, dynamic>.from(a)
      ..['passos'] = '999'
      ..['xp'] = '50'
      ..['atualizado_em'] = 'y';
    expect(impressaoDados(a), impressaoDados(b));
    final c = Map<String, dynamic>.from(a)..['agua'] = '{"d":250}';
    expect(impressaoDados(a), isNot(impressaoDados(c)));
  });
}
