import 'package:flutter/material.dart';
import 'package:mobile_flutter/claim_link.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/src/rust/api/dto.dart';
import 'package:mobile_flutter/theme.dart';
import 'package:mobile_flutter/vault_events.dart';

/// 认领屏:医生代拍的病历存进病人自己的保险箱。
///
/// 病人是从浏览器点「存进我的 MedMe」过来的,此刻他**已经看过这份病历了** ——
/// 所以这一屏不再重复展示内容,只回答一个问题:存进谁的档案。存完给一句人话的结果。
class ClaimScreen extends StatefulWidget {
  const ClaimScreen({super.key, required this.link});
  final ClaimLink link;

  @override
  State<ClaimScreen> createState() => _ClaimScreenState();
}

class _ClaimScreenState extends State<ClaimScreen> {
  late Future<(int, String)> _preview;
  ClaimResultDto? _done;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _preview = widget.link.preview();
  }

  Future<void> _claim() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.link.claim();
      // 档案页在监听这个:存完立刻能看见,不用手动刷新。
      bumpVaultRevision();
      if (mounted) setState(() => _done = r);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MedMe.bg,
      appBar: AppBar(title: const Text('存进我的档案')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _done != null
              ? _result(_done!)
              : FutureBuilder<(int, String)>(
                  future: _preview,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(
                        child: CircularProgressIndicator(color: MedMe.teal),
                      );
                    }
                    if (snap.hasError) return _fatal(snap.error.toString());
                    final (n, name) = snap.data!;
                    return _confirm(n, name);
                  },
                ),
        ),
      ),
    );
  }

  Widget _confirm(int n, String name) {
    final target = ProfileManager.instance.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          name.isEmpty ? '医生为你建的病历' : '$name 的病历',
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: MedMe.tealDark,
          ),
        ),
        const SizedBox(height: 6),
        Text('共 $n 份记录', style: const TextStyle(color: MedMe.faint)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: MedMe.panel,
            border: Border.all(color: MedMe.line),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.person_outline, color: MedMe.teal),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('存进', style: TextStyle(color: MedMe.faint, fontSize: 12)),
                    Text(
                      target.name,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              // 存错人比存错位置麻烦得多 —— 给一条明确的退路,而不是让他事后去挪。
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('换一个'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '存进来之后,这份病历就只在你自己的手机上。云端那份会在保留期结束时删除。',
          style: TextStyle(color: MedMe.faint, fontSize: 13, height: 1.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: MedMe.danger, height: 1.5)),
        ],
        const Spacer(),
        FilledButton(
          onPressed: _busy ? null : _claim,
          style: FilledButton.styleFrom(
            backgroundColor: MedMe.teal,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('存进我的档案', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }

  Widget _result(ClaimResultDto r) {
    // 重复认领不是错误(病人常会再点一次链接),所以这里按「都已在档案里」说话。
    final lines = <String>[
      if (r.imported > 0) '新存入 ${r.imported} 份',
      if (r.deduped > 0) '${r.deduped} 份原本就在你的档案里',
      if (r.textOnly > 0) '${r.textOnly} 份只带回了文字,原件没随包过来',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const Icon(Icons.check_circle, color: MedMe.teal, size: 56),
        const SizedBox(height: 16),
        const Text(
          '已存进你的档案',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(
          lines.isEmpty ? '没有新内容' : lines.join('·'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: MedMe.faint, height: 1.6),
        ),
        const SizedBox(height: 20),
        const Text(
          '医生识别的文字直接带了过来,没有在你手机上重跑一遍 —— 所以内容与医生看到的一致。'
          '有拿不准的地方,请以纸质原件为准。',
          textAlign: TextAlign.center,
          style: TextStyle(color: MedMe.faint, fontSize: 13, height: 1.5),
        ),
        const Spacer(),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(
            backgroundColor: MedMe.teal,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: const Text('去看看', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }

  Widget _fatal(String msg) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Icon(Icons.link_off, color: MedMe.faint, size: 48),
      const SizedBox(height: 16),
      Text(msg, textAlign: TextAlign.center, style: const TextStyle(height: 1.6)),
      const SizedBox(height: 24),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('返回'),
      ),
    ],
  );
}
