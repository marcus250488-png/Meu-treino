# Arquitetura do Meu treino

## Sincronização (v3)
- Dados ficam no aparelho (SharedPreferences, separados por conta) e na nuvem
  (Firestore, documento `users/{uid}/dados/estado`).
- A nuvem guarda o mapa inteiro **compactado** (JSON + gzip + base64) no campo `z`,
  mais `v` (versão do formato) e `atualizado_em`. Isso evita estourar o limite de
  1 MB por documento. Se mesmo compactado passar de ~900 KB, o app mostra erro
  em vez de falhar em silêncio.
- Leitura aceita os dois formatos: o antigo (campos soltos) e o novo (`z`).
  Na primeira sincronização depois da atualização, o app converte sozinho.
- Ao abrir o app (`sincronizar`):
  1. Se o aparelho tem alterações não enviadas (ex.: usou sem internet) e a nuvem
     não mudou desde o último envio, **o aparelho vence** e é enviado.
  2. Caso contrário, a nuvem é aplicada, mesclando as sessões de treino
     dos dois lados.
- "Alterações não enviadas" é detectado por uma impressão digital dos dados
  (`impressaoDados`), que ignora hora, passos e XP.
- Limitação conhecida: se dois aparelhos editarem offline ao mesmo tempo, vale a
  nuvem (exceto sessões de treino, que são mescladas).

## Regras de segurança
`docs/firestore.rules` deve estar publicada em Firebase > Firestore > Regras.

## Build
- O workflow falha se faltarem `KEYSTORE_BASE64` / `KEYSTORE_PASSWORD`
  (evita APK com chave de debug).
- `flutter analyze` e `flutter test` rodam, mas ainda não bloqueiam a build.
  Quando a saída estiver limpa, remover `continue-on-error`.

## Mapa dos arquivos (lib/)
- `state.dart` (~2,2 mil linhas): estado, persistência, login e nuvem.
- `telas.dart` (~3,5 mil): telas principais.
- `nutricao.dart` (~2,1 mil): telas de nutrição.
- demais: `nutri_modelo.dart`, `nivel.dart`, `coach_ia.dart`, `compartilhar.dart`, etc.

## Plano de refatoração (não feito ainda, fazer aos poucos)
1. Tirar de `state.dart` a parte de nuvem/login para `nuvem.dart`.
2. Dividir `telas.dart` em uma tela por arquivo (treino, histórico, evolução...).
3. Dividir `nutricao.dart` em diário, cardápio e alimentos.
4. Um passo por vez, com build verde entre eles.
