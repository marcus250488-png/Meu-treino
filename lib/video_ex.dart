import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'state.dart';
import 'telas.dart';

/// Vídeos de execução.
/// - assets/videos.json liga o id do exercício ao link do vídeo (acervo online).
///   O app baixa o vídeo uma vez, guarda no aparelho e depois toca do arquivo.
/// - Se o exercício não tem link, usa assets/videos/<id>.mp4 (arquivo embutido).
/// - Sem link e sem arquivo = sem vídeo.
class _Fontes {
  final Set<String> locais;
  final Map<String, String> urls;
  _Fontes(this.locais, this.urls);
}

class _Fonte {
  final String? asset;
  final String? url;
  const _Fonte({this.asset, this.url});
}

Future<_Fontes>? _carregando;

Future<_Fontes> _fontes() {
  _carregando ??= _lerFontes();
  return _carregando!;
}

Future<_Fontes> _lerFontes() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final locais = manifest
      .listAssets()
      .where((a) => a.startsWith('assets/videos/') && a.endsWith('.mp4'))
      .map((a) => a.substring(14, a.length - 4))
      .toSet();
  var urls = <String, String>{};
  try {
    final txt = await rootBundle.loadString('assets/videos.json');
    final j = jsonDecode(txt) as Map<String, dynamic>;
    urls = {for (final e in j.entries) e.key: '${e.value}'};
  } catch (_) {}
  return _Fontes(locais, urls);
}

/// Fonte do vídeo do exercício, ou null se não existir.
/// Se o id do treino não tiver vídeo (ex.: exercício criado a partir do PDF),
/// procura na biblioteca um exercício com o mesmo nome que tenha vídeo.
_Fonte? _fonteVideo(String exId, _Fontes f, [String nome = '']) {
  _Fonte? de(String id) {
    final u = f.urls[id];
    if (u != null) return _Fonte(url: u);
    if (f.locais.contains(id)) return _Fonte(asset: 'assets/videos/$id.mp4');
    return null;
  }

  final direto = de(exId);
  if (direto != null) return direto;
  if (nome.isNotEmpty) {
    final n = norm(nome);
    for (final e in app.lib) {
      if (norm(e.nome) == n) {
        final r = de(e.id);
        if (r != null) return r;
      }
    }
  }
  return null;
}

// ---------- Download com cache no aparelho ----------
final Map<String, Future<File>> _baixando = {};

/// Último erro de download (para mostrar na tela e facilitar o diagnóstico).
String ultimoErroVideo = '';

String _descreverErro(Object e) {
  if (e is HttpException) return e.message;
  if (e is SocketException) return 'sem conexão com o servidor (${e.message})';
  if (e is TimeoutException) return 'tempo esgotado';
  return '$e';
}

Future<File> _arquivoDoCache(String url) async {
  final base = await getApplicationSupportDirectory();
  final pasta = Directory('${base.path}/videos_cache');
  if (!await pasta.exists()) await pasta.create(recursive: true);
  final partes = url.split('/');
  final nome = partes.length >= 2
      ? '${partes[partes.length - 2]}_${partes.last}'
      : partes.last;
  return File('${pasta.path}/$nome');
}

/// Baixa o vídeo uma única vez e devolve o arquivo guardado no aparelho.
Future<File> baixarVideoCache(String url) {
  return _baixando.putIfAbsent(
    url,
    () => _baixar(url).whenComplete(() => _baixando.remove(url)),
  );
}

Future<File> _baixar(String url) async {
  final alvo = await _arquivoDoCache(url);
  if (await alvo.exists() && await alvo.length() > 0) return alvo;
  final tmp = File('${alvo.path}.part');
  if (await tmp.exists()) await tmp.delete();
  final cliente = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await cliente.getUrl(Uri.parse(url));
    final resp = await req.close().timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      throw HttpException('HTTP ${resp.statusCode}');
    }
    final sink = tmp.openWrite();
    await resp
        .timeout(const Duration(seconds: 30))
        .pipe(sink)
        .timeout(const Duration(minutes: 5));
    await tmp.rename(alvo.path);
    return alvo;
  } catch (e) {
    ultimoErroVideo = _descreverErro(e);
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  } finally {
    cliente.close(force: true);
  }
}

/// Vídeo do exercício: toca sozinho, sem som e em loop. Toque pausa/retoma.
class VideoExercicio extends StatelessWidget {
  final String exId, nome;
  final double altura, abaixo;
  const VideoExercicio(
      {super.key,
      required this.exId,
      this.nome = '',
      this.altura = 260,
      this.abaixo = 0});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Fontes>(
      future: _fontes(),
      builder: (context, snap) {
        final f = snap.data;
        if (f == null) return const SizedBox.shrink();
        final fonte = _fonteVideo(exId, f, nome);
        if (fonte == null) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(bottom: abaixo),
          child: _PlayerLoop(
            key: ValueKey(fonte.url ?? fonte.asset),
            fonte: fonte,
            altura: altura,
          ),
        );
      },
    );
  }
}

class _PlayerLoop extends StatefulWidget {
  final _Fonte fonte;
  final double altura;
  const _PlayerLoop({super.key, required this.fonte, required this.altura});
  @override
  State<_PlayerLoop> createState() => _PlayerLoopEstado();
}

class _PlayerLoopEstado extends State<_PlayerLoop> {
  VideoPlayerController? _c;
  bool _pronto = false, _erro = false;

  @override
  void initState() {
    super.initState();
    _iniciar();
  }

  void _ouvir() {
    if (mounted) setState(() {});
  }

  Future<void> _iniciar() async {
    try {
      final f = widget.fonte;
      File? arq;
      if (f.url != null) {
        arq = await baixarVideoCache(f.url!);
        if (!mounted) return;
      }
      final opcoes = VideoPlayerOptions(mixWithOthers: true);
      final ctl = arq != null
          ? VideoPlayerController.file(arq, videoPlayerOptions: opcoes)
          : VideoPlayerController.asset(f.asset!, videoPlayerOptions: opcoes);
      _c = ctl;
      await ctl.initialize();
      if (!mounted) return;
      await ctl.setLooping(true);
      await ctl.setVolume(0);
      await ctl.play();
      ctl.addListener(_ouvir);
      if (mounted) setState(() => _pronto = true);
    } catch (e) {
      if (ultimoErroVideo.isEmpty) ultimoErroVideo = _descreverErro(e);
      if (mounted) setState(() => _erro = true);
    }
  }

  Future<void> _tentarDeNovo() async {
    final antigo = _c;
    _c = null;
    antigo?.removeListener(_ouvir);
    await antigo?.dispose();
    if (!mounted) return;
    ultimoErroVideo = '';
    setState(() {
      _erro = false;
      _pronto = false;
    });
    _iniciar();
  }

  @override
  void dispose() {
    _c?.removeListener(_ouvir);
    _c?.dispose();
    super.dispose();
  }

  Widget _caixa(Widget filho, {VoidCallback? aoTocar}) {
    return GestureDetector(
      onTap: aoTocar,
      child: Container(
        height: widget.altura,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(child: filho),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_erro) {
      return _caixa(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  color: Colors.white54, size: 36),
              const SizedBox(height: 8),
              const Text(
                'Não consegui carregar o vídeo.\nToque para tentar de novo.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              if (ultimoErroVideo.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Motivo: $ultimoErroVideo',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
        aoTocar: _tentarDeNovo,
      );
    }
    final c = _c;
    if (!_pronto || c == null) {
      return _caixa(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(height: 10),
            Text('Carregando vídeo…',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      );
    }
    final tocando = c.value.isPlaying;
    // Tamanho padrão: quadrado, qualquer vídeo é recortado (cover) para caber.
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.altura),
        child: AspectRatio(
          aspectRatio: 1,
          child: GestureDetector(
            onTap: () => tocando ? c.pause() : c.play(),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: c.value.size.width,
                      height: c.value.size.height,
                      child: VideoPlayer(c),
                    ),
                  ),
                  if (!tocando)
                    Container(
                      color: Colors.black38,
                      child: const Icon(Icons.play_arrow_rounded,
                          size: 64, color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Botão pequeno "Ver execução" (só aparece se o exercício tem vídeo).
class BotaoVerExecucao extends StatelessWidget {
  final String exId, nome;
  const BotaoVerExecucao({super.key, required this.exId, required this.nome});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Fontes>(
      future: _fontes(),
      builder: (context, snap) {
        final f = snap.data;
        if (f == null || _fonteVideo(exId, f, nome) == null) {
          return const SizedBox.shrink();
        }
        return OutlinedButton.icon(
          style: estiloContornoMini,
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            backgroundColor: kSuperf,
            builder: (c) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nome, style: titulo(28)),
                    const SizedBox(height: 14),
                    VideoExercicio(exId: exId, nome: nome, altura: 420),
                  ],
                ),
              ),
            ),
          ),
          icon: const Icon(Icons.play_circle_outline, size: 16),
          label: const Text('Ver execução'),
        );
      },
    );
  }
}

// ---------- Baixar de uma vez os vídeos do plano (use no Wi-Fi) ----------
Future<void> abrirBaixarVideosDoPlano(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _DialogoBaixarVideos(),
  );
}

class _DialogoBaixarVideos extends StatefulWidget {
  const _DialogoBaixarVideos();
  @override
  State<_DialogoBaixarVideos> createState() => _DialogoBaixarVideosEstado();
}

class _DialogoBaixarVideosEstado extends State<_DialogoBaixarVideos> {
  int _feitos = 0, _total = 0, _falhas = 0;
  bool _fim = false, _cancelado = false;

  @override
  void initState() {
    super.initState();
    _rodar();
  }

  @override
  void dispose() {
    _cancelado = true;
    super.dispose();
  }

  Future<void> _rodar() async {
    final f = await _fontes();
    final urls = <String>{};
    for (final d in app.plano) {
      for (final it in d.itens) {
        final x = _fonteVideo(it.exId, f, it.nome);
        final u = x?.url;
        if (u != null) urls.add(u);
      }
    }
    if (!mounted) return;
    setState(() => _total = urls.length);
    for (final u in urls) {
      if (_cancelado || !mounted) return;
      try {
        await baixarVideoCache(u);
      } catch (_) {
        _falhas++;
      }
      if (!mounted) return;
      setState(() => _feitos++);
    }
    if (mounted) setState(() => _fim = true);
  }

  @override
  Widget build(BuildContext context) {
    final String msg;
    if (!_fim) {
      msg = _total == 0 ? 'Procurando os vídeos do plano…' : '$_feitos de $_total';
    } else if (_total == 0) {
      msg = 'Nenhum exercício do seu plano usa vídeo por link.';
    } else if (_falhas == 0) {
      msg = 'Pronto! Os vídeos do seu plano já funcionam sem internet.';
    } else {
      msg =
          'Terminou, mas $_falhas vídeo(s) não baixaram. Confira a internet e tente de novo.';
    }
    return AlertDialog(
      title: const Text('Baixar vídeos do plano'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_fim || _total > 0)
            LinearProgressIndicator(
              value: _total == 0 ? null : _feitos / _total,
            ),
          const SizedBox(height: 12),
          Text(msg),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_fim ? 'Fechar' : 'Cancelar'),
        ),
      ],
    );
  }
}

// ---------- Baixar TODOS os vídeos de uma vez (use no Wi-Fi) ----------
Future<Directory> _pastaCache() async {
  final base = await getApplicationSupportDirectory();
  final pasta = Directory('${base.path}/videos_cache');
  if (!await pasta.exists()) await pasta.create(recursive: true);
  return pasta;
}

/// [quantidade de vídeos baixados, bytes ocupados].
Future<List<int>> resumoVideosBaixados() async {
  var n = 0, bytes = 0;
  try {
    final pasta = await _pastaCache();
    await for (final e in pasta.list()) {
      if (e is File && !e.path.endsWith('.part')) {
        n++;
        bytes += await e.length();
      }
    }
  } catch (_) {}
  return [n, bytes];
}

Future<void> apagarVideosBaixados() async {
  final pasta = await _pastaCache();
  if (await pasta.exists()) await pasta.delete(recursive: true);
}

String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(0)} MB';

Future<void> abrirBaixarTodosVideos(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _DialogoBaixarTodos(),
  );
}

class _DialogoBaixarTodos extends StatefulWidget {
  const _DialogoBaixarTodos();
  @override
  State<_DialogoBaixarTodos> createState() => _DialogoBaixarTodosEstado();
}

class _DialogoBaixarTodosEstado extends State<_DialogoBaixarTodos> {
  List<String> _urls = [];
  int _ok = 0, _falhas = 0, _arquivos = 0, _bytes = 0;
  bool _pronto = false, _rodando = false, _fim = false, _cancelado = false;

  @override
  void initState() {
    super.initState();
    _preparar();
  }

  @override
  void dispose() {
    _cancelado = true;
    super.dispose();
  }

  Future<void> _atualizarResumo() async {
    final r = await resumoVideosBaixados();
    if (!mounted) return;
    setState(() {
      _arquivos = r[0];
      _bytes = r[1];
    });
  }

  Future<void> _preparar() async {
    final f = await _fontes();
    final u = f.urls.values.toSet().toList()..sort();
    if (!mounted) return;
    setState(() {
      _urls = u;
      _pronto = true;
    });
    await _atualizarResumo();
  }

  Future<void> _baixarTodos() async {
    ultimoErroVideo = '';
    setState(() {
      _rodando = true;
      _fim = false;
      _cancelado = false;
      _ok = 0;
      _falhas = 0;
    });
    final fila = List<String>.from(_urls);
    var i = 0;
    Future<void> trabalhador() async {
      while (!_cancelado && mounted) {
        if (i >= fila.length) return;
        final u = fila[i++];
        try {
          await baixarVideoCache(u);
          if (mounted) setState(() => _ok++);
        } catch (_) {
          if (mounted) setState(() => _falhas++);
        }
        if ((_ok + _falhas) % 10 == 0) _atualizarResumo();
      }
    }

    await Future.wait([trabalhador(), trabalhador(), trabalhador()]);
    if (!mounted) return;
    setState(() {
      _rodando = false;
      _fim = !_cancelado;
    });
    await _atualizarResumo();
  }

  Future<void> _apagar() async {
    await apagarVideosBaixados();
    if (!mounted) return;
    setState(() {
      _fim = false;
      _ok = 0;
      _falhas = 0;
    });
    await _atualizarResumo();
  }

  @override
  Widget build(BuildContext context) {
    final total = _urls.length;
    final feitos = _ok + _falhas;
    final String msg;
    if (!_pronto) {
      msg = 'Procurando os vídeos…';
    } else if (_rodando && _cancelado) {
      msg = 'Parando…';
    } else if (_rodando) {
      msg = 'Baixando… $feitos de $total. Mantenha o app aberto.';
    } else if (_fim && _falhas == 0) {
      msg = 'Pronto! Os $total vídeos estão no celular e funcionam sem internet.';
    } else if (_fim) {
      msg =
          'Terminou, mas $_falhas vídeo(s) não baixaram. Toque em "Baixar os que faltam" quando a internet estiver melhor.';
    } else {
      msg =
          'São $total vídeos. Recomendado no Wi-Fi: pode usar bastante dados e espaço.';
    }
    return AlertDialog(
      title: const Text('Baixar todos os vídeos'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_rodando || _fim)
            LinearProgressIndicator(
              value: total == 0 ? null : feitos / total,
            ),
          const SizedBox(height: 12),
          Text(msg),
          const SizedBox(height: 8),
          Text(
            'No celular agora: $_arquivos vídeos (${_mb(_bytes)})',
            style: const TextStyle(color: kMudo, fontSize: 12),
          ),
          if (_falhas > 0 && ultimoErroVideo.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Último erro: $ultimoErroVideo',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        if (!_rodando && _arquivos > 0)
          TextButton(onPressed: _apagar, child: const Text('Apagar')),
        TextButton(
          onPressed: _rodando
              ? () => setState(() => _cancelado = true)
              : () => Navigator.pop(context),
          child: Text(_rodando ? 'Parar' : 'Fechar'),
        ),
        if (!_rodando)
          FilledButton(
            onPressed: _pronto && total > 0 ? _baixarTodos : null,
            child: Text(_arquivos == 0 ? 'Baixar todos' : 'Baixar os que faltam'),
          ),
      ],
    );
  }
}
