// 「清空所有数据 · 重置保险箱」的**顺序契约**回归测试(BUG-3)。
//
// ## 钉的是什么
//
// `wipeAllData()` 里有两件事必须按序发生:**先把磁盘删干净,最后才开箱**。
// 反序过一次,后果是:清空之后 App 到重启之前写不进任何东西 —— 手动录入、导入、
// 载入示例统统炸在 `AnyhowException(io: No such file or directory (os error 2))`。
// 因为被删掉的目录里就包含刚刚开好的那个箱子:恢复出厂之后 root 成员 `p-1` 自己也
// 住在 `<docs>/profiles/p-1/`(`ProfileManager.localBaseOf` 对所有成员一视同仁),
// 所以 `profiles/` 不是「子成员目录」,而是**全部**成员目录。
//
// 读还是好的(走已打开的连接/内存态),所以「已清空」这个反馈是真的 —— 坏的是
// 之后所有的**写**。这条测试因此不去看「清空成不成功」,而是看:**清空回来之后,
// 那个开着的箱子在磁盘上还在不在、还写不写得进去。**
//
// ## 为什么用假的 vault 而不是真 FFI
//
// `flutter test` 不加载 Rust 原生库(与 `manual_entry_sheet_test.dart` 顶部同一条
// 限制),`open_vault`/`reset_vault` 在这里调用会直接崩。所以把这两个动作换成
// [_FakeVault] —— 它照着 Rust 的真实语义演:
//
//   · `open`  → `create_dir_all(<base>/vault)`,并记住「现在开在这里」
//                (对应 `open_vault` 开头那两行 `std::fs::create_dir_all`);
//   · `reset` → 删掉当前 truth_root 再在原地重建(对应 `reset_vault`);
//   · `write` → 往**当前开着的** truth_root 里写一个文件 —— 目录被删了就抛
//                `FileSystemException: No such file or directory`,正是用户看到的
//                那句红字。
//
// 目录是**真的**临时目录,删除也是**真的** `Directory.delete` —— 被替换掉的只有
// 「Rust 那一侧」。于是这条测试验的是真实的文件系统顺序,不是一串 mock 的调用记录。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/profile_manager.dart';
import 'package:mobile_flutter/vault_boot.dart';

/// Rust 侧 vault 的替身。**进程级单例**这一点也照着演:同一时刻只有一个 `openAt`。
class _FakeVault {
  /// 当前开着的 truth_root;null = 一个箱子都没开(对应 Rust 的「保险箱尚未打开」)。
  String? openAt;

  /// 调用流水,用来断言顺序。
  final calls = <String>[];

  Future<void> open(String base) async {
    final root = '$base/vault';
    await Directory(root).create(recursive: true); // = open_vault 的 create_dir_all
    openAt = root;
    calls.add('open');
  }

  Future<void> reset() async {
    final root = openAt;
    if (root == null) throw StateError('保险箱尚未打开');
    final d = Directory(root);
    if (await d.exists()) await d.delete(recursive: true);
    await d.create(recursive: true); // reset_vault 会在原地重开一个空的
    calls.add('reset');
  }

  /// 一次真实写入。**这就是用户清空之后做的第一件事**(录一条血压 / 导一份病历)。
  Future<void> write() async =>
      File('${openAt!}/medme.db').writeAsString('x');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late String docsRoot;
  late String containerRoot;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('medme-wipe-test');
    docsRoot = '${sandbox.path}/docs';
    containerRoot = '${sandbox.path}/icloud';
    // ProfileManager / ReviewState 都把状态落在 support 目录里。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '${sandbox.path}/support',
        );
    await Directory('${sandbox.path}/support').create(recursive: true);
  });

  tearDown(() async => sandbox.delete(recursive: true));

  /// 清空之前的样子:两个成员各有一箱数据,当前开在其中一个上。
  Future<_FakeVault> seed() async {
    final pm = ProfileManager.instance;
    await pm.ensureLoaded();
    await pm.factoryReset();
    final other = await pm.create('李秀英');
    final vault = _FakeVault();
    // root p-1 与 p-2 各建一箱,当前活跃 = p-2(用户正待在别人档案里点的清空)。
    await vault.open(pm.localBaseOf(docsRoot, 'p-1'));
    await File('${vault.openAt}/medme.db').writeAsString('root 的病历');
    await vault.open(pm.localBaseOf(docsRoot, other!));
    await File('${vault.openAt}/medme.db').writeAsString('李秀英的病历');
    // iCloud 容器里也留一份(关掉 iCloud 时 disable_icloud_sync 会保留它)。
    await Directory('$containerRoot/Documents/profiles/p-1/vault')
        .create(recursive: true);
    await File('$containerRoot/Documents/profiles/p-1/vault/medme.db')
        .writeAsString('容器里的副本');
    vault.calls.clear();
    return vault;
  }

  Future<void> wipe(_FakeVault vault, {String? container}) => runWipeSequence(
    docsRoot: docsRoot,
    containerRoot: container,
    releaseActiveVault: vault.reset,
    openFreshRootVault: () =>
        vault.open(ProfileManager.instance.localBase(docsRoot)),
  );

  test('清空之后立刻还写得进去 —— 开着的箱子必须真的存在于磁盘上', () async {
    final vault = await seed();
    await wipe(vault, container: containerRoot);

    // 这一条就是 BUG-3 的本体。旧顺序下 `openAt` 指向一个已经被 rm 掉的目录,
    // 这里会抛 `FileSystemException: ... No such file or directory`。
    expect(
      Directory(vault.openAt!).existsSync(),
      isTrue,
      reason: '清空回来之后开着的箱子指向一个不存在的目录 —— 之后所有的写都会炸',
    );
    await vault.write(); // 抛出即失败
  });

  test('顺序契约:开箱是最后一个 vault 动作,它后面不许再有任何删除', () async {
    final vault = await seed();
    await wipe(vault, container: containerRoot);

    expect(vault.calls, ['reset', 'open'], reason: '先松手,删完盘,最后开箱');
    expect(
      vault.calls.last,
      'open',
      reason: 'wipeAllData 的最后一个 vault 动作必须是「开」—— 加新步骤时守住这条',
    );
  });

  test('删得干净:两个根下的 profiles/(**全部**成员,含 root)与遗留的 vault/ 都没了', () async {
    final vault = await seed();
    // 多成员布局之前 root 待过的老位置,也要一起清掉。
    await Directory('$docsRoot/vault').create(recursive: true);
    await File('$docsRoot/vault/medme.db').writeAsString('老布局的遗留');

    await wipe(vault, container: containerRoot);

    expect(
      Directory('$docsRoot/profiles/p-2').existsSync(),
      isFalse,
      reason: '别的成员的数据必须删干净',
    );
    expect(
      File('$docsRoot/vault/medme.db').existsSync(),
      isFalse,
      reason: '遗留的老位置也要清',
    );
    expect(
      Directory('$containerRoot/Documents/profiles').existsSync(),
      isFalse,
      reason: '只删本机的话,再开 iCloud 会把整份病历 adopt 回来(评审 Critical)',
    );
    // 唯一还在的,是最后重开出来的那个空箱子。
    expect(vault.openAt, '$docsRoot/profiles/p-1/vault');
    expect(Directory(vault.openAt!).existsSync(), isTrue);
    expect(
      Directory(vault.openAt!).listSync(),
      isEmpty,
      reason: '重开出来的应该是个空箱子,不是把谁的数据留下了',
    );
  });

  test('恢复出厂:成员表回到单一默认 root,而开的正是它', () async {
    final vault = await seed();
    await wipe(vault, container: containerRoot);

    final pm = ProfileManager.instance;
    expect(pm.profiles.length, 1);
    expect(pm.currentId.value, 'p-1');
    expect(
      vault.openAt,
      '${pm.localBase(docsRoot)}/vault',
      reason: '恢复出厂要在开箱**之前**发生,否则开的是清空前那个成员的箱子',
    );
  });

  test('本次启动压根没开过箱(reset 抛「保险箱尚未打开」)也要清完并开好', () async {
    final vault = await seed();
    vault.openAt = null; // VaultBootstrap 开箱失败的那种启动

    await wipe(vault, container: containerRoot);

    expect(vault.calls, ['open'], reason: 'reset 抛了,不该让整个清空半途而废');
    expect(Directory('$docsRoot/profiles/p-2').existsSync(), isFalse);
    expect(vault.openAt, '$docsRoot/profiles/p-1/vault');
    await vault.write();
  });

  test('iCloud 容器不可用(非 iOS / 容器没解析出来)时不碰任何容器路径', () async {
    final vault = await seed();
    await wipe(vault, container: null);

    expect(
      Directory('$containerRoot/Documents/profiles/p-1/vault').existsSync(),
      isTrue,
      reason: '拿不到容器路径时不该去猜一个路径删',
    );
    expect(Directory('$docsRoot/profiles/p-2').existsSync(), isFalse);
    await vault.write();
  });
}
